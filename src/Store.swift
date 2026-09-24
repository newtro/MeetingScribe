import Foundation

enum Channel: String, Sendable {
    case remote, local

    var label: String { self == .remote ? "REMOTE" : "LOCAL" }
}

struct Utterance: Identifiable, Sendable {
    let id = UUID()
    let t: Date
    let ch: Channel
    let text: String
}

enum Paths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/MeetingScribe", isDirectory: true)
    static let context = root.appendingPathComponent("context.md")
    static let contexts = root.appendingPathComponent("contexts", isDirectory: true)
    static let sessions = root.appendingPathComponent("sessions", isDirectory: true)

    /// Every available brief: the original context.md plus anything in contexts/.
    /// Newest-modified first, so the brief written for today's meeting is the default.
    static func briefs() -> [URL] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: context.path) { urls.append(context) }
        let more = (try? FileManager.default.contentsOfDirectory(at: contexts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        urls += more.filter { $0.pathExtension.lowercased() == "md" }
        return urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    static func briefName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}

enum Fmt {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func jsonString(_ s: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? enc.encode(s), let out = String(data: d, encoding: .utf8) else { return "\"\"" }
        return out
    }
}

/// Appends finalized utterances and suggestions to the session directory.
/// Every write goes straight to the fd and is fsync'd, because another process tails these files.
final class SessionStore: @unchecked Sendable {
    let dir: URL
    let start: Date
    private let queue = DispatchQueue(label: "SessionStore")
    private let jsonl: FileHandle
    private let txt: FileHandle
    private var suggestions: FileHandle?

    init(start: Date) throws {
        self.start = start
        let d = Paths.sessions.appendingPathComponent(Fmt.iso.string(from: start), isDirectory: true)
        dir = d
        let fm = FileManager.default
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        func open(_ name: String) throws -> FileHandle {
            let url = d.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            return h
        }
        jsonl = try open("transcript.jsonl")
        txt = try open("transcript.txt")
    }

    func append(_ u: Utterance) {
        let json = "{\"t\":\"\(Fmt.iso.string(from: u.t))\",\"ch\":\"\(u.ch.rawValue)\",\"text\":\(Fmt.jsonString(u.text))}\n"
        let line = "[\(Fmt.clock.string(from: u.t))] \(u.ch.label): \(u.text)\n"
        queue.sync {
            write(jsonl, json)
            write(txt, line)
        }
    }

    func appendSuggestions(_ markdown: String) {
        queue.sync {
            if suggestions == nil {
                let url = dir.appendingPathComponent("suggestions.md")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                suggestions = try? FileHandle(forWritingTo: url)
                _ = try? suggestions?.seekToEnd()
            }
            if let h = suggestions { write(h, markdown) }
        }
    }

    private func write(_ h: FileHandle, _ s: String) {
        do {
            try h.write(contentsOf: Data(s.utf8))
            try h.synchronize()
        } catch {
            NSLog("MeetingScribe write failed: \(error)")
        }
    }

    func close() {
        queue.sync {
            try? jsonl.close()
            try? txt.close()
            try? suggestions?.close()
        }
    }
}
