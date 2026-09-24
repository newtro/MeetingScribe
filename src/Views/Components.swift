import AppKit
import SwiftUI

enum Palette {
    static let remote = Color(red: 0.20, green: 0.56, blue: 0.86)
    static let local = Color(red: 0.93, green: 0.55, blue: 0.16)
    static let rec = Color(red: 0.84, green: 0.13, blue: 0.15)
    static let highlight = Color(red: 0.96, green: 0.76, blue: 0.10)

    static func tag(_ k: SuggestionKind) -> Color {
        switch k {
        case .flag: return Color(red: 0.88, green: 0.13, blue: 0.13)
        case .ask: return Color(red: 0.22, green: 0.48, blue: 0.94)
        case .answer: return Color(red: 0.15, green: 0.62, blue: 0.34)
        case .note: return .gray
        }
    }

    /// Distinct hues per speaker slot; remote slots in cool colors, local in warm ones.
    static func speaker(_ spk: String?, channel: Channel) -> Color {
        guard let spk, let n = Int(spk.dropFirst()) else { return channel == .remote ? remote : local }
        let cool: [Color] = [remote, .teal, .indigo, .purple, .cyan, .mint, .blue, .gray]
        let warm: [Color] = [local, .pink, .brown, .red, .yellow, .orange, .gray, .gray]
        return (channel == .remote ? cool : warm)[(n - 1) % 8]
    }
}

/// Card surface used across screens.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title.uppercased())
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Speakers

/// Colored speaker label. Click to name the speaker (writes speakers.json for the session).
struct SpeakerChip: View {
    let u: Utterance
    let names: [String: String]
    let onRename: ((String, String) -> Void)?
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        let color = Palette.speaker(u.spk, channel: u.ch)
        Button {
            guard u.spk != nil, onRename != nil else { return }
            text = u.spk.flatMap { names[$0] } ?? ""
            editing = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(Speakers.display(u, names: names))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(u.spk.map { "\(u.ch.label) speaker \($0) — click to name" } ?? u.ch.label)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name \(u.ch == .remote ? "remote" : "local") speaker \(u.spk ?? "")").font(.headline)
                TextField("e.g. Bethany Hunter", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(commit)
                HStack {
                    Text("Applies to every line from this speaker.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save", action: commit).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func commit() {
        if let spk = u.spk { onRename?(spk, text) }
        editing = false
    }
}

/// Everyone heard so far, as chips — a quick way to name speakers.
struct SpeakerRoster: View {
    let utterances: [Utterance]
    let names: [String: String]
    let onRename: ((String, String) -> Void)?

    var body: some View {
        let firsts = Dictionary(grouping: utterances.filter { $0.spk != nil }, by: { $0.spk! })
            .compactMap { $0.value.first }
            .sorted { ($0.ch == .remote ? 0 : 1, $0.spk!) < ($1.ch == .remote ? 0 : 1, $1.spk!) }
        if !firsts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(firsts) { u in
                        SpeakerChip(u: u, names: names, onRename: onRename)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Palette.speaker(u.spk, channel: u.ch).opacity(0.12)))
                    }
                }
            }
        }
    }
}

// MARK: - Transcript

/// Transcript rows (utterances and marked moments) with search. Used live and for past sessions.
struct TranscriptList: View {
    let utterances: [Utterance]
    let names: [String: String]
    let highlights: [Highlight]
    var volatile: [Channel: String] = [:]
    var follow = false
    let onRename: ((String, String) -> Void)?
    @State private var query = ""

    private enum Row: Identifiable {
        case line(Utterance), moment(Highlight)
        var id: String {
            switch self {
            case .line(let u): return u.id.uuidString
            case .moment(let h): return "h\(h.t.timeIntervalSince1970)"
            }
        }
        var t: Date {
            switch self {
            case .line(let u): return u.t
            case .moment(let h): return h.t
            }
        }
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var r: [Row] = utterances.filter {
            q.isEmpty || $0.text.lowercased().contains(q) || Speakers.display($0, names: names).lowercased().contains(q)
        }.map(Row.line)
        if q.isEmpty || !highlights.filter({ $0.note.lowercased().contains(q) }).isEmpty {
            r += highlights.filter { q.isEmpty || $0.note.lowercased().contains(q) }.map(Row.moment)
        }
        return r.sorted { $0.t < $1.t }
    }

    /// A new speaker, or the same one after a pause or a marked moment, starts a turn and gets a label.
    private func startsTurn(_ rows: [Row], _ i: Int) -> Bool {
        guard i > 0, case .line(let u) = rows[i], case .line(let p) = rows[i - 1] else { return true }
        return p.ch != u.ch || p.spk != u.spk || u.t.timeIntervalSince(p.t) > 60
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcript", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Text("\(rows.count) match\(rows.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary)
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12).padding(.top, 10)

            SpeakerRoster(utterances: utterances, names: names, onRename: onRename)
                .padding(.horizontal, 12).padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let all = rows
                        ForEach(Array(all.enumerated()), id: \.element.id) { i, row in
                            switch row {
                            case .line(let u):
                                UtteranceRow(u: u, names: names, onRename: onRename, showSpeaker: startsTurn(all, i))
                            case .moment(let h): MomentRow(h: h)
                            }
                        }
                        if query.isEmpty {
                            ForEach([Channel.remote, .local], id: \.self) { ch in
                                if let v = volatile[ch], !v.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text("live").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).frame(width: 58, alignment: .leading)
                                        Text(ch == .remote ? "Remote" : "Local").font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle((ch == .remote ? Palette.remote : Palette.local).opacity(0.7))
                                        Text(v).italic().foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if rows.isEmpty && volatile.values.allSatisfy(\.isEmpty) {
                            Text(query.isEmpty ? "No transcript yet." : "No matches.")
                                .foregroundStyle(.secondary).padding(.top, 30).frame(maxWidth: .infinity)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: utterances.count) { if follow && query.isEmpty { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
                .onChange(of: volatile) { if follow && query.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }
}

struct UtteranceRow: View {
    let u: Utterance
    var names: [String: String] = [:]
    var onRename: ((String, String) -> Void)? = nil
    var showSpeaker = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Fmt.clock.string(from: u.t)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if showSpeaker { SpeakerChip(u: u, names: names, onRename: onRename).padding(.top, 4) }
                Text(u.text).font(.body).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MomentRow: View {
    let h: Highlight
    var body: some View {
        HStack(spacing: 10) {
            Text(Fmt.clock.string(from: h.t)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            Label(h.note.isEmpty ? "Marked moment" : h.note, systemImage: "bookmark.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Palette.highlight.opacity(0.28)))
        }
    }
}

// MARK: - Suggestions

struct SuggestionCard: View {
    let s: Suggestion
    let fontSize: Double
    let isLatest: Bool

    var body: some View {
        let c = Palette.tag(s.kind)
        let isFlag = s.kind == .flag
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.kind.rawValue)
                    .font(.system(size: max(12, fontSize * 0.5), weight: .black))
                    .foregroundStyle(isFlag ? c : .white)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isFlag ? Color.white : c))
                Text(Fmt.clock.string(from: s.at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isFlag ? .white.opacity(0.85) : .secondary)
            }
            .frame(width: max(84, fontSize * 3.2), alignment: .leading)
            Text(s.text)
                .font(.system(size: isFlag ? fontSize * 1.05 : fontSize, weight: isFlag ? .bold : .semibold))
                .foregroundStyle(isFlag ? .white : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(isFlag ? c : c.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFlag ? Color.white.opacity(0.9) : c.opacity(0.5), lineWidth: isFlag ? 3 : 1)
        )
        .shadow(color: isFlag && isLatest ? c.opacity(0.35) : .clear, radius: 10, y: 3)
        .opacity(isLatest ? 1 : 0.62)
    }
}

extension Suggestion {
    /// Parses suggestions.md ("## HH:MM:SS" then "- **KIND** — text") back into cards, newest first.
    static func parse(markdown: String, day: Date) -> [Suggestion] {
        var out: [Suggestion] = []
        var at = day
        let cal = Calendar.current
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let parts = line.dropFirst(3).split(separator: ":").compactMap { Int($0) }
                if parts.count == 3 {
                    at = cal.date(bySettingHour: parts[0], minute: parts[1], second: parts[2], of: day) ?? day
                }
            } else if line.hasPrefix("- **"), let end = line.range(of: "** — ") {
                let kind = SuggestionKind(rawValue: String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound])) ?? .note
                out.append(Suggestion(at: at, kind: kind, text: String(line[end.upperBound...])))
            } else if line.hasPrefix("  "), let last = out.popLast() {
                out.append(Suggestion(at: last.at, kind: last.kind, text: last.text + "\n" + line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return out.reversed()
    }
}

// MARK: - Markdown

/// Small block-level Markdown renderer (headings, bullets, checkboxes, numbered lists, code, paragraphs).
struct MarkdownView: View {
    let text: String
    var baseSize: CGFloat = 14

    private enum Block: Hashable {
        case h(Int, String), bullet(Int, String), check(Bool, String), numbered(String, String), code(String), para(String), rule
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); out.append(.rule); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...4).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                flush(); out.append(.h(hashes, String(line.dropFirst(hashes + 1)))); continue
            }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flush(); out.append(.check(!line.hasPrefix("- [ ]"), String(line.dropFirst(6)))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); out.append(.bullet(indent, String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); out.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            // An indented line right after a list item continues that item (hard-wrapped Markdown).
            if indent > 0, para.isEmpty, let last = out.last {
                switch last {
                case .bullet(let i, let t): out[out.count - 1] = .bullet(i, t + " " + line); continue
                case .check(let d, let t): out[out.count - 1] = .check(d, t + " " + line); continue
                case .numbered(let n, let t): out[out.count - 1] = .numbered(n, t + " " + line); continue
                default: break
                }
            }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: baseSize * 0.55) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .h(let level, let s):
                    inline(s)
                        .font(.system(size: baseSize * [1.0, 1.7, 1.35, 1.12, 1.0][level], weight: level <= 2 ? .bold : .semibold))
                        .padding(.top, level <= 2 ? baseSize * 0.6 : baseSize * 0.3)
                case .bullet(let indent, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }
                    .padding(.leading, CGFloat(indent) * 18)
                case .check(let done, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                        inline(s)
                    }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
                        inline(s)
                    }
                case .code(let s):
                    Text(s).font(.system(size: baseSize * 0.9, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                case .para(let s):
                    inline(s)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: baseSize))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }
}

// MARK: - Misc

extension URL {
    /// "~/Documents/Clients/Acme" for display.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

func elapsedString(from: Date, to: Date) -> String {
    let s = max(0, Int(to.timeIntervalSince(from)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
