import Foundation

enum SuggestionKind: String, Sendable {
    case ask = "ASK", flag = "FLAG", answer = "ANSWER", note = "NOTE"
}

struct Suggestion: Identifiable, Sendable {
    let id = UUID()
    let at: Date
    let kind: SuggestionKind
    let text: String
}

/// Shells out to `claude -p`. The prompt is context.md verbatim plus the labeled transcript window —
/// context.md owns the instructions and the output contract; nothing is layered on top.
final class Advisor: @unchecked Sendable {
    static let claudePath = "/Users/scott/.local/bin/claude"
    static let window: TimeInterval = 4 * 60
    static let timeout: TimeInterval = 30

    private let lock = NSLock()
    private var contextURL = Paths.context
    private var contextText = ""
    private var contextMTime: Date?
    private var inFlight = false
    private var recentKeys: [[(SuggestionKind, Set<String>)]] = []   // items from recent responses

    enum Outcome: Sendable {
        case items([Suggestion])
        case silent
        case skipped(String)
        case failed(String)
    }

    /// Which brief governs this meeting. Changing it drops the cached text and the repeat history.
    func setContext(_ url: URL) {
        lock.withLock {
            guard url != contextURL else { return }
            contextURL = url
            contextText = ""
            contextMTime = nil
            recentKeys.removeAll()
        }
    }

    /// Re-reads the brief only when its mtime changes, so it can be edited mid-meeting.
    private func currentContext() throws -> String {
        let url = lock.withLock { contextURL }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs[.modificationDate] as? Date
        if mtime != contextMTime || contextText.isEmpty {
            contextText = try String(contentsOf: url, encoding: .utf8)
            contextMTime = mtime
        }
        return contextText
    }

    static func transcriptBlock(_ utterances: [Utterance], now: Date) -> String {
        let cutoff = now.addingTimeInterval(-window)
        return utterances
            .filter { $0.t >= cutoff }
            .sorted { $0.t < $1.t }
            .map { u in
                let spk = u.spk.map { " speaker \($0)" } ?? ""
                let who = u.ch == .remote ? "REMOTE\(spk) (call audio)" : "LOCAL\(spk) (Scott's microphone)"
                return "[\(Fmt.clock.string(from: u.t))] \(who): \(u.text)"
            }
            .joined(separator: "\n")
    }

    /// Runs one cycle off the caller's thread. Drops the cycle if one is already running.
    func run(utterances: [Utterance]) async -> Outcome {
        let acquired = lock.withLock { () -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        if !acquired { return .skipped("previous check still running") }
        defer { lock.withLock { inFlight = false } }

        let now = Date()
        let transcript = Self.transcriptBlock(utterances, now: now)
        if transcript.isEmpty { return .skipped("no transcript in the last 4 minutes") }
        let context: String
        do { context = try currentContext() } catch { return .failed("can't read brief: \(error.localizedDescription)") }

        let prompt = context + "\n\n---\n\n# Live transcript, last 4 minutes\n\n" + transcript + "\n"

        let result = await Self.runClaude(prompt: prompt)
        switch result {
        case .failure(let msg):
            return .failed(msg)
        case .success(let out):
            let items = Self.parse(out, at: now)
            if items.isEmpty { return .silent }
            let fresh = dedupe(items)
            return fresh.isEmpty ? .silent : .items(fresh)
        }
    }

    enum RunResult { case success(String), failure(String) }

    static func runClaude(prompt: String) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claudePath)
                p.arguments = ["-p", "--output-format", "text",
                               "--tools", "", "--strict-mcp-config", "--no-session-persistence"]
                // Neutral cwd so no project CLAUDE.md is picked up.
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/Users/scott/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = errPipe

                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                do { try p.run() } catch {
                    cont.resume(returning: .failure("can't launch claude: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                var timedOut = false
                let killer = DispatchWorkItem {
                    if p.isRunning { timedOut = true; p.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                _ = group.wait(timeout: .now() + 2)
                if timedOut {
                    cont.resume(returning: .failure("timed out after \(Int(timeout))s, cycle dropped"))
                } else if p.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(returning: .failure("claude exited \(p.terminationStatus): \(err.prefix(200))"))
                } else {
                    cont.resume(returning: .success(String(data: outData, encoding: .utf8) ?? ""))
                }
            }
        }
    }

    // MARK: parsing

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s*|\d+[.)]\s*)?[*_#\s]*\b(ASK|FLAG|ANSWER)\b[*_]*\s*[:—–\-]*\s*[*_]*\s*(.*)$"#)

    /// Splits the response into tagged items. Untagged text that is short is treated as silence
    /// (e.g. "Nothing worth saying."); longer untagged text is kept as a NOTE rather than dropped.
    static func parse(_ raw: String, at: Date) -> [Suggestion] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        var items: [(SuggestionKind, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = tagRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let kind = SuggestionKind(rawValue: ns.substring(with: m.range(at: 1))) ?? .note
                items.append((kind, ns.substring(with: m.range(at: 2))))
            } else if !items.isEmpty {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { items[items.count - 1].1 += "\n" + t }
            }
        }
        if items.isEmpty {
            if text.count < 120 { return [] }
            return [Suggestion(at: at, kind: .note, text: text)]
        }
        return items.map { Suggestion(at: at, kind: $0.0, text: clean($0.1)) }.filter { !$0.text.isEmpty }
    }

    private static func clean(_ s: String) -> String {
        // Bold markers aren't rendered and the model sometimes bolds "FLAG — headline." as one span.
        var t = s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("**") || t.hasPrefix("—") || t.hasPrefix(":") {
            t = String(t.drop(while: { "*—: ".contains($0) }))
        }
        return t
    }

    // MARK: dedupe

    /// Generic words, including the CR boilerplate context.md suggests, so two FLAGs that both say
    /// "outside the SOW, I'll bring back a CR" are not mistaken for the same item.
    private static let stop: Set<String> = Set("""
        the and for that this with you your are was were has have had not but its it's from into out outside
        sow scope scoped change request bring back hours cost real solve say now let sits covers what properly
        rather than guess room will i'll we our they their them there then here just also same need needs name
        before after about which when where who how does did can could should would may might one two all any
        each per via these those note flag ask answer don't doesn't isn't that's
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Drops items that repeat an item of the same kind from the last 3 responses, so the same suggestion
    /// does not re-surface every 45s. Similarity = overlap of content words (measured on real reworded repeats:
    /// repeats scored 0.40–1.0, distinct items ≤ 0.17).
    private func dedupe(_ items: [Suggestion]) -> [Suggestion] {
        lock.withLock { dedupeLocked(items) }
    }

    private func dedupeLocked(_ items: [Suggestion]) -> [Suggestion] {
        let previous = recentKeys.flatMap { $0 }
        var kept: [Suggestion] = []
        var keys: [(SuggestionKind, Set<String>)] = []
        for item in items {
            let w = Self.words(item.text)
            let dup = previous.contains { (k, p) in
                guard k == item.kind else { return false }
                if w.count < 3 || p.count < 3 { return w == p }
                return Double(w.intersection(p).count) / Double(min(w.count, p.count)) >= 0.35
            }
            keys.append((item.kind, w))
            if !dup { kept.append(item) }
        }
        recentKeys.append(keys)
        if recentKeys.count > 3 { recentKeys.removeFirst() }
        return kept
    }

    static func markdown(_ items: [Suggestion]) -> String {
        guard let first = items.first else { return "" }
        var s = "## \(Fmt.clock.string(from: first.at))\n\n"
        for i in items { s += "- **\(i.kind.rawValue)** — \(i.text.replacingOccurrences(of: "\n", with: "\n  "))\n" }
        return s + "\n"
    }
}
