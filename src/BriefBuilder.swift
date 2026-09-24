import Foundation

/// Has Claude write (or revise) a meeting brief from the user's description plus the folders they chose.
///
/// Claude runs headless and can read, not write: Read/Glob/Grep anywhere under the home folder (the chosen folders
/// come first), Bash limited to the CLI's read-only commands, and WebSearch only if the user allows it. There are no
/// write tools, and `--restricted` ignores the user's own Claude settings and refuses bypassPermissions, so a
/// permissive local allow rule can't turn the shell into a writer. Anything Claude reads is sent to Claude; nothing
/// is written anywhere but the brief.
final class BriefBuilder: @unchecked Sendable {
    enum Event: Sendable {
        case step(String)       // a tool call, e.g. "Reading docs/SOW.md"
        case thinking(String)   // a short line of Claude's own narration
    }

    static let timeout: TimeInterval = 15 * 60
    private let run = ClaudeCLI.Run()

    func cancel() { run.cancel() }

    /// Builds a new brief, or revises `current` according to `instruction`. Returns the brief markdown.
    func build(_ info: MeetingInfo, current: String? = nil, instruction: String? = nil,
               onEvent: @escaping @Sendable (Event) -> Void) async throws -> String {
        let folders = info.materialURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        var tools = ["Read", "Glob", "Grep", "Bash"]
        var allowed = ["Read", "Glob", "Grep"]
        if info.allowWeb { tools.append("WebSearch"); allowed.append("WebSearch") }

        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--restricted", "--strict-mcp-config", "--no-session-persistence",
                    "--tools", tools.joined(separator: ","),
                    "--allowedTools"] + allowed
        for extra in folders.dropFirst() { args += ["--add-dir", extra.path] }
        args += ["--add-dir", NSHomeDirectory()]
        if let model = UserDefaults.standard.string(forKey: Prefs.briefModel), !model.isEmpty { args += ["--model", model] }

        let prompt = Self.prompt(info, folders: folders, current: current, instruction: instruction)
        let cwd = folders.first ?? FileManager.default.temporaryDirectory
        let result = ResultBox()
        _ = try await run.run(args: args, cwd: cwd, stdin: prompt, timeout: Self.timeout) { line in
            Self.handle(line: line, cwd: cwd, result: result, onEvent: onEvent)
        }
        guard let text = result.value else {
            throw ClaudeCLI.Failure(message: result.error ?? "Claude returned no brief")
        }
        return try Self.extractBrief(text)
    }

    // MARK: - stream-json

    private final class ResultBox: @unchecked Sendable {
        var value: String?
        var error: String?
    }

    private static func handle(line: String, cwd: URL, result: ResultBox, onEvent: @Sendable (Event) -> Void) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = o["type"] as? String else { return }
        if type == "result" {
            if (o["is_error"] as? Bool) == true {
                result.error = (o["result"] as? String) ?? (o["subtype"] as? String) ?? "Claude reported an error"
            } else {
                result.value = o["result"] as? String
            }
            return
        }
        guard type == "assistant", let msg = o["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return }
        for c in content {
            switch c["type"] as? String {
            case "tool_use":
                onEvent(.step(describe(tool: c["name"] as? String ?? "", input: c["input"] as? [String: Any] ?? [:], cwd: cwd)))
            case "text":
                let t = (c["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip the brief itself; keep short narration like "Now checking the SOW."
                if !t.isEmpty && !t.hasPrefix("#") && t.count < 400 {
                    onEvent(.thinking(t.components(separatedBy: .newlines).first ?? t))
                }
            default: break
            }
        }
    }

    static func describe(tool: String, input: [String: Any], cwd: URL) -> String {
        func rel(_ p: String?) -> String {
            guard let p else { return "" }
            let base = cwd.path.hasSuffix("/") ? cwd.path : cwd.path + "/"
            return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : (p as NSString).lastPathComponent
        }
        switch tool {
        case "Read": return "Reading \(rel(input["file_path"] as? String))"
        case "Glob": return "Listing \(input["pattern"] as? String ?? "files")"
        case "Grep": return "Searching for “\(input["pattern"] as? String ?? "")”"
        case "Bash": return "Running \(input["command"] as? String ?? "a command")"
        case "WebSearch": return "Searching the web for “\(input["query"] as? String ?? "")”"
        default: return tool
        }
    }

    /// The brief starts at its first `# ` heading; anything before it is chatter.
    static func extractBrief(_ text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) else {
            throw ClaudeCLI.Failure(message: "Claude's reply wasn't a brief: \(text.prefix(200))")
        }
        var body = lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("```") { body = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return body + "\n"
    }

    // MARK: - Prompt

    /// Branch, status and recent history for a folder that is a git work tree; nil otherwise.
    static func gitSnapshot(_ folder: URL) -> String? {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", folder.path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard git(["rev-parse", "--is-inside-work-tree"]) == "true" else { return nil }
        let parts = [
            ("git status -sb", git(["status", "-sb"])),
            ("git branch -a", git(["branch", "-a", "--sort=-committerdate"]).map { $0.components(separatedBy: "\n").prefix(15).joined(separator: "\n") }),
            ("git log (last 30)", git(["log", "-30", "--date=short", "--pretty=format:%h %ad %an  %s"])),
            ("contributors", git(["shortlog", "-sn", "--all", "HEAD"])),
        ]
        return parts.compactMap { name, out in out.map { "$ \(name)\n\($0)" } }.joined(separator: "\n\n")
    }

    static func prompt(_ info: MeetingInfo, folders: [URL], current: String?, instruction: String?) -> String {
        let user = Prefs.user
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
        var p = """
        You are preparing a context brief for MeetingScribe, a Mac app that listens to a live meeting. Every \
        45 seconds it sends this brief, verbatim, plus the last 4 minutes of transcript to an AI advisor that \
        shows \(user) short ASK / FLAG / ANSWER items on screen. The brief is the advisor's ONLY knowledge and \
        its ONLY instructions, so it must be self-contained, specific and correct.

        Today is \(today). The user is \(user).

        ## The meeting, in \(user)'s words

        Title: \(info.title.isEmpty ? "(untitled)" : info.title)
        Attendees: \(info.attendees.isEmpty ? "(not given — infer from the materials if you can)" : info.attendees)

        \(info.description.isEmpty ? "(no description given)" : info.description)

        """
        if folders.isEmpty {
            p += "\nThere are no materials. Work from the description alone and do not invent facts.\n"
        } else {
            p += "\n## Materials\n\nStart from these folders:\n"
            p += folders.map { "- \($0.path)" }.joined(separator: "\n")
            p += """


            Explore them with Glob, Grep, Read and read-only shell commands (git log/show/blame, ls, find, …). \
            You may read elsewhere on this Mac if something points there. You cannot write files. Start broad \
            (list files, read READMEs, contracts, SOWs, specs, notes, emails), then go deep on whatever matters \
            for this meeting. Large folders: be selective, don't read everything. Every fact in the brief must \
            come from the materials or the description — cite the source file inline as `path`. If something \
            important is unknown, it becomes a question, never a guess.

            """
        }
        let repos = folders.compactMap { f in gitSnapshot(f).map { "### \(f.path)\n\n```\n\($0)\n```" } }
        if !repos.isEmpty {
            p += "\n## Repository state (collected by the app)\n\n" + repos.joined(separator: "\n\n") + "\n"
        }
        if info.allowWeb {
            p += "\nYou may use WebSearch for public background on the organizations and people involved. Mark web facts as such.\n"
        }

        if let current, let instruction {
            p += """

            ## Revise an existing brief

            Here is the current brief:

            <brief>
            \(current)
            </brief>

            \(user) asks for this change: \(instruction)

            Make that change (checking the materials again if needed), keep everything else that is still right, \
            and output the complete revised brief.

            """
        }

        p += """

        ## Write the brief in exactly this shape

        # <Meeting title> context brief

        One short paragraph: "You are listening to a live meeting and advising \(user) in real time. Everything \
        below is ground truth, taken from <sources> as of <date>. When the transcript conflicts with it, say so."

        ## Your job
        Keep these rules (adapt the wording of the three definitions to this meeting's purpose):
        - Return at most 3 items per cycle. Return nothing if nothing is worth saying. Silence is correct most \
        of the time.
        - Each item is one line that starts with **ASK**, **FLAG** or **ANSWER** followed by " — ":
          - **ASK** — a question \(user) should put to the room now, because the moment is right.
          - **FLAG** — something just said that commits \(user)'s side to something it can't or shouldn't do, \
        states something untrue, or settles a decision without an owner and a date.
          - **ANSWER** — a fact from this brief that answers a question just asked in the room.
        - Be specific and short. Do not summarize the conversation, restate what was said, or offer encouragement.
        - Transcript lines are labeled REMOTE (call audio) or LOCAL (\(user)'s microphone), with anonymous \
        speaker slots like R2 or names when known.

        ## The meeting
        Purpose, format, what is and isn't agreed or signed, what's at stake.

        ## People
        Who is on each side, roles, who decides, what each cares about.

        ## <Topic sections — as many as the materials justify, named for the subject>
        The ground truth the advisor needs: what exists, what doesn't, numbers, dates, scope, status, risks. \
        Dense bullet points with concrete names. Include a "does NOT do / out of scope — FLAG any commitment" \
        list whenever it applies.

        ## Accuracy guardrails — FLAG if anyone says otherwise
        The claims most likely to be misstated in the room, stated correctly.

        ## Questions \(user) needs answered
        Grouped by priority, most important first.

        ## What \(user) should leave with
        A checklist of outcomes.

        Aim for 1,000–2,500 words. Output ONLY the brief in Markdown, starting with the "# " title line — no \
        preamble, no closing remarks, no code fences.
        """
        return p
    }
}

/// Post-meeting summary from the full transcript, the brief, the user's notes and marked moments.
enum Summarizer {
    static let timeout: TimeInterval = 5 * 60

    static func summarize(files: SessionFiles, briefURL: URL?) async throws -> String {
        let names = files.speakers
        let lines = files.utterances.sorted { $0.t < $1.t }
        guard !lines.isEmpty else { throw ClaudeCLI.Failure(message: "no transcript to summarize") }
        let transcript = lines.map { "[\(Fmt.clock.string(from: $0.t))] \(Advisor.speakerLabel($0, names: names)): \($0.text)" }
            .joined(separator: "\n")
        let brief = briefURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let notes = files.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlights = files.highlights.map { "- \(Fmt.clock.string(from: $0.t)) \($0.note)" }.joined(separator: "\n")
        let user = Prefs.user

        var p = """
        Summarize this meeting for \(user). Write for someone who was there and needs the record and the follow-ups.
        Use the brief (if any) as background for what mattered; use the transcript as the record of what was said.
        Transcripts are machine-made: fix obvious mis-hearings silently, never invent content. Speaker slots like \
        R2 are anonymous unless named. When unsure who said something, say "someone on the call".

        Output Markdown. The first line is `# ` plus a short, specific title for the meeting (≤ 8 words, e.g. \
        "Park Lawn punchout setup kickoff"). Then exactly these sections (omit one only if it would be empty):

        ## Summary
        3–6 sentences.
        ## Decisions
        - Each decision, who made it.
        ## Action items
        - [ ] **Owner** — task — due date if one was said
        ## Open questions
        - Unresolved questions and who needs to answer them.
        ## Risks and flags
        - Commitments, contradictions or scope issues worth a second look (use the brief's facts).
        ## Follow-up email
        A short, ready-to-send recap email from \(user) to the other attendees.

        Output only the Markdown, no preamble.

        """
        if !brief.isEmpty { p += "\n<brief>\n\(brief)\n</brief>\n" }
        if !notes.isEmpty { p += "\n<my_notes>\n\(notes)\n</my_notes>\n" }
        if !highlights.isEmpty { p += "\n<marked_moments>\n\(highlights)\n</marked_moments>\n" }
        p += "\n<transcript>\n\(transcript)\n</transcript>\n"

        let out = try await ClaudeCLI.Run().run(
            args: ["-p", "--output-format", "text", "--tools", "", "--strict-mcp-config", "--no-session-persistence"],
            cwd: FileManager.default.temporaryDirectory, stdin: p, timeout: timeout)
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeCLI.Failure(message: "Claude returned an empty summary") }
        return text + "\n"
    }
}
