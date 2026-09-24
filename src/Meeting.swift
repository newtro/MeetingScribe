import Foundation

// Additive per-session files. transcript.jsonl / transcript.txt / suggestions.md are the contract another
// session reads live; everything here sits beside them and never changes their meaning:
//   meeting.json      title, description, brief, materials, start/end
//   speakers.json     {"R2": "Bethany Hunter"} — display names for diarized speaker slots
//   notes.md          the user's own notes
//   highlights.jsonl  {"t","note"} — moments marked during the meeting
//   summary.md        post-meeting summary written by Claude

/// What the user told us about a meeting before it started. Also stored beside a generated brief
/// (`contexts/.meta/<name>.json`) so the brief can be refined and the meeting prefilled later.
struct MeetingInfo: Codable, Equatable, Sendable {
    var title = ""
    var description = ""
    var attendees = ""
    var materials: [String] = []          // folder paths
    var allowWeb = false
    var brief: String?                    // brief path used for the session
    var started: Date?
    var ended: Date?

    var materialURLs: [URL] { materials.map { URL(fileURLWithPath: $0) } }
}

struct Highlight: Codable, Identifiable, Equatable, Sendable {
    var id: Date { t }
    let t: Date
    var note: String
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Reads and writes the additive files of one session directory. Safe for live and past sessions.
struct SessionFiles: Sendable {
    let dir: URL

    var meetingURL: URL { dir.appendingPathComponent("meeting.json") }
    var speakersURL: URL { dir.appendingPathComponent("speakers.json") }
    var notesURL: URL { dir.appendingPathComponent("notes.md") }
    var highlightsURL: URL { dir.appendingPathComponent("highlights.jsonl") }
    var summaryURL: URL { dir.appendingPathComponent("summary.md") }
    var suggestionsURL: URL { dir.appendingPathComponent("suggestions.md") }
    var transcriptURL: URL { dir.appendingPathComponent("transcript.jsonl") }

    var meeting: MeetingInfo? { JSON.read(MeetingInfo.self, from: meetingURL) }
    func save(meeting: MeetingInfo) { JSON.write(meeting, to: meetingURL) }

    var speakers: [String: String] { JSON.read([String: String].self, from: speakersURL) ?? [:] }
    func save(speakers: [String: String]) { JSON.write(speakers.filter { !$0.value.isEmpty }, to: speakersURL) }

    var notes: String { (try? String(contentsOf: notesURL, encoding: .utf8)) ?? "" }
    func save(notes: String) {
        if notes.isEmpty && !FileManager.default.fileExists(atPath: notesURL.path) { return }
        try? notes.write(to: notesURL, atomically: true, encoding: .utf8)
    }

    var summary: String? { try? String(contentsOf: summaryURL, encoding: .utf8) }
    func save(summary: String) { try? summary.write(to: summaryURL, atomically: true, encoding: .utf8) }

    var suggestionsMarkdown: String { (try? String(contentsOf: suggestionsURL, encoding: .utf8)) ?? "" }

    var highlights: [Highlight] {
        guard let text = try? String(contentsOf: highlightsURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSON.decoder.decode(Highlight.self, from: Data($0.utf8)) }
    }

    func append(highlight: Highlight) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(highlight) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: highlightsURL.path) { fm.createFile(atPath: highlightsURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: highlightsURL) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
        try? h.close()
    }

    func rewrite(highlights: [Highlight]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let text = highlights.compactMap { (try? enc.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
            .joined(separator: "\n")
        try? (text.isEmpty ? "" : text + "\n").write(to: highlightsURL, atomically: true, encoding: .utf8)
    }

    /// Parses transcript.jsonl (tolerates a partially written last line).
    var utterances: [Utterance] {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = o["t"] as? String, let t = Fmt.iso.date(from: ts),
                  let ch = Channel(rawValue: o["ch"] as? String ?? ""),
                  let text = o["text"] as? String else { return nil }
            return Utterance(t: t, ch: ch, text: text, spk: o["spk"] as? String)
        }
    }
}

/// One row of the meeting library.
struct SessionInfo: Identifiable, Hashable, Sendable {
    var id: URL { dir }
    let dir: URL
    let start: Date
    let title: String
    let duration: TimeInterval?
    let lineCount: Int
    let hasSummary: Bool

    static func load(_ dir: URL) -> SessionInfo? {
        guard let start = Fmt.iso.date(from: dir.lastPathComponent) else { return nil }
        let f = SessionFiles(dir: dir)
        let meeting = f.meeting
        let lines = f.utterances
        let end = meeting?.ended ?? lines.map(\.t).max()
        let title = meeting.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
            ?? meeting?.brief.map { Paths.briefName(URL(fileURLWithPath: $0)) }
            ?? "Untitled meeting"
        return SessionInfo(dir: dir, start: start, title: title,
                           duration: end.map { $0.timeIntervalSince(start) },
                           lineCount: lines.count,
                           hasSummary: FileManager.default.fileExists(atPath: f.summaryURL.path))
    }

    static func all() -> [SessionInfo] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap(load).sorted { $0.start > $1.start }
    }
}

extension Paths {
    static let briefMeta = contexts.appendingPathComponent(".meta", isDirectory: true)

    static func metaURL(forBrief brief: URL) -> URL {
        briefMeta.appendingPathComponent(brief.deletingPathExtension().lastPathComponent + ".json")
    }

    /// A new, unused brief path in contexts/ derived from the meeting title.
    static func newBriefURL(title: String, date: Date = Date()) -> URL {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let slug = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.last == "-") { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = "\(day.string(from: date))-\(slug.isEmpty ? "meeting" : String(slug.prefix(60)))"
        var url = contexts.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = contexts.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return url
    }
}

enum Export {
    /// A self-contained Markdown record of the meeting: summary, notes, highlights, transcript with names.
    static func markdown(files: SessionFiles, info: SessionInfo?) -> String {
        let names = files.speakers
        let meeting = files.meeting
        var s = "# \(info?.title ?? meeting?.title ?? "Meeting")\n\n"
        if let start = info?.start {
            s += "\(DateFormatter.localizedString(from: start, dateStyle: .full, timeStyle: .short))"
            if let d = info?.duration { s += " · \(Fmt.duration(d))" }
            s += "\n\n"
        }
        if let summary = files.summary, !summary.isEmpty { s += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
        let notes = files.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += "## My notes\n\n\(notes)\n\n" }
        let hl = files.highlights
        if !hl.isEmpty {
            s += "## Marked moments\n\n"
            for h in hl { s += "- \(Fmt.clock.string(from: h.t))\(h.note.isEmpty ? "" : " — \(h.note)")\n" }
            s += "\n"
        }
        s += "## Transcript\n\n"
        for u in files.utterances.sorted(by: { $0.t < $1.t }) {
            s += "**\(Fmt.clock.string(from: u.t)) \(Speakers.display(u, names: names))** \(u.text)\n\n"
        }
        return s
    }
}

enum Speakers {
    /// "Bethany Hunter", "Remote 2", "Local 1", or the channel when undiarized.
    static func display(_ u: Utterance, names: [String: String]) -> String {
        guard let spk = u.spk else { return u.ch == .remote ? "Remote" : "Local" }
        if let n = names[spk], !n.isEmpty { return n }
        return (u.ch == .remote ? "Remote " : "Local ") + spk.dropFirst()
    }
}

extension Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s / 60) % 60) }
        return "\(max(1, s / 60)) min"
    }
}
