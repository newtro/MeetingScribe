import Foundation

/// Synthetic inputs, fake providers and local process fixtures only. Never invokes Claude.
enum LiveAdviceTests {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func result(_ text: String) -> ModelResult {
        ModelResult(text: text, receipt: ModelReceipt(requestedModel: "offline-fixture"))
    }
    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    static func event(id: UUID = UUID(), revision: Int = 1, final: Bool = true, retracted: Bool = false) -> SpeechEvent {
        SpeechEvent(id: id, revision: revision, channel: .remote, t: Date(), start: 0, end: 1,
                    text: "The connections are created, but sharing is pending.", final: final, retracted: retracted, speaker: nil)
    }
    static func excerpt(date: Date = Date().addingTimeInterval(-60)) -> SourceExcerpt {
        SourceExcerpt(source: SourceRecord(id: "source-a", relativePath: "notes/readiness.md", contentHash: "fixture",
                                           startLine: 2, endLine: 3, observedAt: date, modifiedAt: nil, authoredAt: nil,
                                           kind: .requirement, repositoryID: nil, revision: nil, environment: "test", truncated: false),
                      text: "Sharing is required before binding and testing.")
    }
    static func cue(_ event: SpeechEvent, source: String = "source-a") -> ProposedCue {
        ProposedCue(text: "The requirement says sharing must precede binding and testing.", kind: "ANSWER", claimKind: .fact,
                    sourceIDs: [source], quotes: ["Sharing is required before binding and testing."], issueID: nil,
                    trigger: SpeechReference(id: event.id, revision: event.revision), assumptions: [], validation: "")
    }

    actor Gate {
        var started = false
        var prompt = ""
        var continuation: CheckedContinuation<ModelResult, Never>?
        func wait(prompt: String = "") async -> ModelResult {
            self.prompt = prompt
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func release(_ result: ModelResult) { continuation?.resume(returning: result); continuation = nil }
    }
    actor WorkerProbe {
        var calls = 0
        var cancelled = 0
        var roles: [ModelRole] = []
        func answer(role: ModelRole) async throws -> ModelResult {
            calls += 1; roles.append(role)
            if calls == 1 {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                catch { cancelled += 1; throw error }
            }
            return LiveAdviceTests.result("{\"cue\":null,\"unknown\":\"Not established\"}")
        }
    }

    @MainActor static func waitUntil(_ label: String, _ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await predicate()) {
            if Date() > deadline { throw Failure(message: "Timed out waiting for \(label)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func run() async throws -> [String] {
        var passed: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingScribe-advice-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func directory(_ name: String) throws -> URL {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        // Regression from a real Haiku response: readable issue IDs previously passed the schema
        // and then caused the entire attention response to fail UUID decoding.
        let schema = AdviceSchemas.listener
        let properties = schema["properties"] as! [String: Any]
        let issueSchema = (properties["issues"] as! [String: Any])["items"] as! [String: Any]
        let idSchema = (issueSchema["properties"] as! [String: Any])["id"] as! [String: Any]
        let expression = try NSRegularExpression(pattern: idSchema["pattern"] as! String)
        func matches(_ text: String) -> Bool { expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        try check(!matches("retest-owner") && matches(UUID().uuidString), "Attention schema must reject invented readable issue IDs")
        let empty = Data(#"{"schemaVersion":1,"topics":[],"issues":[{"id":null,"title":"Retest","question":"Who owns the retest?","state":"open","priority":3,"reason":"Decision pending","trigger":{"id":"11111111-1111-1111-1111-111111111111","revision":1}}],"cue":null,"research":[]}"#.utf8)
        let decodedIssue = try JSONDecoder().decode(ListenerResponse.self, from: empty).issues[0]
        try check(decodedIssue.id == nil, "New issues must accept app-assigned identity")
        passed.append("Attention protocol: strict existing UUIDs and app-assigned new issue identity")

        let setting = ModelPolicy.defaultSetting(for: .detect)
        let args = try ModelRunner.arguments(setting: setting, fast: false, schema: nil)
        try check(args.contains("--safe-mode") && args.contains("--restricted") && args.contains("--strict-mcp-config"), "Missing no-customization flags")
        try check(args.contains("claude-haiku-5-5") && args.contains("low"), "Role model/effort missing")
        let parsed = try ModelRunner.parse("{\"type\":\"result\",\"is_error\":false,\"structured_output\":{\"ok\":true},\"modelUsage\":{\"claude-haiku-5-5\":{}},\"usage\":{\"input_tokens\":5}}", setting: setting, fast: true, elapsed: 0.1, requiresJSON: true)
        try check(parsed.text.contains("true") && parsed.receipt.resolvedModels == ["claude-haiku-5-5"] && parsed.receipt.effectiveSpeed == "unknown", "Receipt invented effective speed/model")
        for (detail, unavailable) in [("model_not_found", true), ("rate_limit_error", false)] {
            do {
                _ = try ModelRunner.parse("{\"type\":\"result\",\"is_error\":true,\"result\":\"\(detail)\"}", setting: setting, fast: false, elapsed: 0, requiresJSON: false)
                throw Failure(message: "Error result accepted")
            } catch let error as ModelRunner.ProviderFailure { try check(error.modelUnavailable == unavailable, "Incorrect fallback classification") }
        }
        passed.append("Explicit model configuration, structured output, honest Fast receipt and fallback classification")

        let cancelled = ClaudeCLI.Run(executableURL: URL(fileURLWithPath: "/usr/bin/touch"))
        cancelled.cancel()
        let marker = root.appendingPathComponent("must-not-exist")
        do {
            _ = try await cancelled.run(args: [marker.path], cwd: root, stdin: "", timeout: 2)
            throw Failure(message: "Cancelled process launched")
        } catch is CancellationError { }
        try check(!FileManager.default.fileExists(atPath: marker.path), "Cancellation-before-launch wrote a marker")
        passed.append("Cancelled-before-launch process never starts")

        let bounded = ClaudeCLI.Run(executableURL: URL(fileURLWithPath: "/usr/bin/yes"))
        let capStart = Date()
        do {
            _ = try await bounded.run(args: ["fixture"], cwd: root, stdin: "", deadline: Date().addingTimeInterval(3), stdoutLimit: 1024)
            throw Failure(message: "Output cap not enforced")
        } catch let failure as ClaudeCLI.Failure { try check(failure.message.contains("limit"), "Wrong output-cap failure") }
        try check(Date().timeIntervalSince(capStart) < 3, "Output cap did not bound process lifetime")
        passed.append("Bounded stdout drains and terminates a continuously writing process")

        let stubborn = ClaudeCLI.Run(executableURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let stubbornStart = Date()
        do {
            _ = try await stubborn.run(args: ["-c", "import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(20)"],
                                       cwd: root, stdin: "", timeout: 0.35)
            throw Failure(message: "Ignored termination escaped timeout")
        } catch let failure as ClaudeCLI.Failure { try check(failure.message.contains("timed out"), "Wrong timeout failure") }
        try check(Date().timeIntervalSince(stubbornStart) < 3.5, "SIGKILL escalation failed")
        passed.append("Ignored SIGTERM escalates to owned-process SIGKILL after two seconds")

        let failing = ClaudeCLI.Run(executableURL: URL(fileURLWithPath: "/bin/sh"))
        do {
            _ = try await failing.run(args: ["-c", "printf '%s\\n' '{\"type\":\"result\",\"is_error\":true,\"result\":\"model_not_found\"}'\nexit 1"], cwd: root, stdin: "", timeout: 2)
            throw Failure(message: "Nonzero status accepted")
        } catch let failure as ClaudeCLI.Failure {
            try check(failure.stdout?.contains("model_not_found") == true && !failure.message.contains("model_not_found"), "Nonzero structured result lost or leaked")
        }
        passed.append("Nonzero CLI error retains bounded protocol JSON without exposing it as an error message")

        var queue = ResearchQueue()
        let session = UUID(), now = Date()
        for index in 0..<4 {
            _ = queue.submit(ResearchRequest(sessionID: session, packetID: nil, issueID: UUID(), trigger: nil,
                                             typedQuestionID: UUID(), transcriptRevision: 0, query: "question \(index)", priority: 0,
                                             submittedAt: now, deadline: now.addingTimeInterval(20)))
        }
        let urgent = ResearchRequest(sessionID: session, packetID: nil, issueID: UUID(), trigger: nil,
                                     typedQuestionID: UUID(), transcriptRevision: 0, query: "urgent", priority: 3,
                                     submittedAt: now, deadline: now.addingTimeInterval(20))
        try check(queue.submit(urgent) && queue.pending.count == 4 && queue.next()?.id == urgent.id, "Urgent queue admission/order failed")
        passed.append("Queue remains bounded at four and urgent work replaces queued speculation")

        for test in ["valid", "partial", "unknown-source", "future-source"] {
            let speech = event(final: test != "partial")
            let proposed = cue(speech, source: test == "unknown-source" ? "fabricated" : "source-a")
            let payload = try json(ListenerResponse(schemaVersion: 1, topics: [], issues: [], cue: proposed, research: []))
            let provider = AdviceProvider(detect: { _ in result(payload) }, answer: { _, _, _, _ in result("{}") })
            let coordinator = LiveMeetingCoordinator(provider: provider, debounceNanoseconds: 0)
            coordinator.start(sessionID: UUID(), sessionDir: try directory(test), packet: nil)
            coordinator.setCorpus([excerpt(date: test == "future-source" ? Date().addingTimeInterval(60) : Date().addingTimeInterval(-60))])
            coordinator.ingest(speech)
            try await waitUntil("\(test) detector") { coordinator.lastReceipt != nil }
            try check(coordinator.cues.count == (test == "valid" ? 1 : 0), "Cue evidence/finality guard failed: \(test)")
            if test == "valid" {
                try check(coordinator.cues[0].evidence.contains("notes/readiness.md:2"), "Evidence lacks human-readable location")
                coordinator.ingest(event(id: speech.id, revision: 2, retracted: true))
                try check(coordinator.cues[0].status == "superseded", "Retraction left cue active")
            }
            coordinator.stop()
        }
        passed.append("Source/quote/finality/time-cutoff checks reject unsupported cues; retraction supersedes accepted cue")

        let lateGate = Gate(), lateSpeech = event()
        let lateProvider = AdviceProvider(detect: { _ in await lateGate.wait() }, answer: { _, _, _, _ in result("{}") })
        let late = LiveMeetingCoordinator(provider: lateProvider, debounceNanoseconds: 0)
        late.start(sessionID: UUID(), sessionDir: try directory("old-session"), packet: nil)
        late.setCorpus([excerpt()]); late.ingest(lateSpeech)
        try await waitUntil("late provider start") { await lateGate.started }
        late.start(sessionID: UUID(), sessionDir: try directory("new-session"), packet: nil)
        await lateGate.release(result(try json(ListenerResponse(schemaVersion: 1, topics: [], issues: [], cue: cue(lateSpeech), research: []))))
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(late.cues.isEmpty && late.lastReceipt == nil, "Old session result published into new session")
        late.stop()
        passed.append("Provider ignoring cancellation still cannot publish across session switch")

        let revisionGate = Gate(), original = event()
        let revisionProvider = AdviceProvider(detect: { _ in await revisionGate.wait() }, answer: { _, _, _, _ in result("{}") })
        let revisionLive = LiveMeetingCoordinator(provider: revisionProvider, debounceNanoseconds: 0)
        revisionLive.start(sessionID: UUID(), sessionDir: try directory("revised-speech"), packet: nil)
        revisionLive.setCorpus([excerpt()]); revisionLive.ingest(original)
        try await waitUntil("revision provider") { await revisionGate.started }
        revisionLive.ingest(event(id: original.id, revision: 2))
        await revisionGate.release(result(try json(ListenerResponse(schemaVersion: 1, topics: [], issues: [], cue: cue(original), research: []))))
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(revisionLive.cues.isEmpty, "Outdated segment revision published a cue")
        revisionLive.stop()
        passed.append("Revised speech invalidates in-flight responses independently of cancellation")

        let backgroundGate = Gate()
        let quiet = try json(ListenerResponse(schemaVersion: 1, topics: [], issues: [], cue: nil, research: []))
        let backgroundProvider = AdviceProvider(detect: { _ in result(quiet) }, answer: { prompt, _, _, _ in await backgroundGate.wait(prompt: prompt) })
        let background = LiveMeetingCoordinator(provider: backgroundProvider, debounceNanoseconds: 0)
        background.start(sessionID: UUID(), sessionDir: try directory("background"), packet: nil)
        background.ask("What should we check?")
        try await waitUntil("background worker") { await backgroundGate.started }
        let capturedPrompt = await backgroundGate.prompt
        let issueLine = capturedPrompt.components(separatedBy: "\n").first { $0.hasPrefix("Issue ID: ") } ?? ""
        guard let issueID = UUID(uuidString: String(issueLine.dropFirst("Issue ID: ".count))) else { throw Failure(message: "Typed request lost issue identity") }
        background.ingest(event()) // Conversation advances while the request is in flight.
        let proposal = ProposedCue(text: "Could we verify sharing before the next test?", kind: "ASK", claimKind: .proposal,
                                   sourceIDs: [], quotes: [], issueID: issueID, trigger: nil, assumptions: [], validation: "Inspect sharing, then perform a test.")
        let answer = "{\"cue\":" + (try json(proposal)) + ",\"unknown\":\"\"}"
        await backgroundGate.release(result(answer))
        try await waitUntil("background publication") { background.backgroundCues.count == 1 }
        try check(background.cues.isEmpty, "Late research interrupted the prompter")
        background.showBackground(cueID: background.backgroundCues[0].id)
        try check(background.cues.count == 1 && background.backgroundCues.isEmpty, "User could not reveal completed background research")
        background.stop()
        passed.append("Late research stays outside prompter until explicit user reveal")

        let researchSpeech = event(), probe = WorkerProbe()
        let researchPayload = try json(ListenerResponse(schemaVersion: 1, topics: [], issues: [], cue: nil,
            research: [DetectedResearch(issueID: nil, query: "sharing requirement", priority: 1,
                                        trigger: SpeechReference(id: researchSpeech.id, revision: researchSpeech.revision))]))
        let researchProvider = AdviceProvider(detect: { _ in result(researchPayload) }, answer: { _, role, _, _ in try await probe.answer(role: role) })
        let live = LiveMeetingCoordinator(provider: researchProvider, debounceNanoseconds: 0)
        live.start(sessionID: UUID(), sessionDir: try directory("urgent-preemption"), packet: nil)
        live.setCorpus([excerpt()]); live.ingest(researchSpeech)
        try await waitUntil("research worker") { await probe.calls == 1 }
        live.ask("What remains before testing?")
        try await waitUntil("urgent preemption") { await probe.calls == 2 }
        let cancellations = await probe.cancelled, roles = await probe.roles
        try check(cancellations == 1 && roles == [.research, .cue], "Urgent Ask failed to preempt research/use cue role")
        try check(live.issues.contains(where: { $0.reason == "Typed question" && $0.trigger == nil }), "Typed Ask became synthetic speech")
        live.stop()
        passed.append("Urgent typed Ask preempts speculation, uses cue role, and retains separate provenance")
        return passed
    }
}
