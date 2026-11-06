import Foundation

/// Offline fixtures only: no provider, capture, account or real meeting-library access.
enum ProjectWorkflowTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ProjectFailure("Project workflow test: " + message) }
    }
    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
    static func git(_ root: URL, _ args: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-C", root.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProjectFailure("Fixture Git command failed: \(args.first ?? "unknown")") }
        return String(decoding: data, as: UTF8.self)
    }
    static func result(_ prompt: String) throws -> ModelResult {
        let regex = try NSRegularExpression(pattern: #"<SOURCE id="([a-f0-9]+)">[\s\S]*?Truncated: (?:true|false)\n([^\n]+)"#)
        let text = prompt as NSString
        guard let match = regex.firstMatch(in: prompt, range: NSRange(location: 0, length: text.length)) else { throw ProjectFailure("Offline provider received no source.") }
        let id = text.substring(with: match.range(at: 1)), quote = text.substring(with: match.range(at: 2))
        let object: [String: Any] = [
            "claims": [["key": "documented", "text": "The source documents: " + quote, "kind": "fact", "scope": "sourceContent", "sourceIDs": [id], "quotes": [quote], "environment": NSNull(), "dateQualifier": NSNull()]],
            "summaryClaimKeys": ["documented"], "topics": [["key": "review", "title": "Review", "claimKeys": ["documented"], "priority": "attention", "reason": "Review the documented next step."]],
            "openQuestions": ["What should be checked next?"], "coverageNotes": ["Offline synthetic fixture."]]
        return ModelResult(text: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), receipt: ModelReceipt(requestedModel: "offline-fixture", resolvedModels: ["offline-fixture"]))
    }
    @MainActor static func until(_ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(6)
        while !(await condition()) {
            guard Date() < end else { throw ProjectFailure("Offline workflow fixture did not reach its expected state.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func run() async throws -> [String] {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("MeetingScribe-ProjectTests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Alpha"), beta = temporary.appendingPathComponent("Beta")
        try write("The review is pending. See nested/notes.md and repo/src/feature.swift.\n", to: root.appendingPathComponent("AGENTS.md"))
        try write("Nested decision remains open.\n", to: root.appendingPathComponent("nested/notes.md"))
        try write("Useful hidden history.\n", to: root.appendingPathComponent(".claude/history.md"))
        try write("Useful hidden handoff.\n", to: root.appendingPathComponent(".Codex/handoff.md"))
        try write("The beta review is pending.\n", to: beta.appendingPathComponent("README.md"))
        for path in [".env.md", ".claude/settings.json", ".claude/worktrees/other/notes.md", "secrets/notes.md", "build/notes.md", "credentials.json"] {
            try write("DO_NOT_READ_SECRET_SENTINEL", to: root.appendingPathComponent(path))
        }
        let outside = temporary.appendingPathComponent("outside.md")
        try write("DO_NOT_READ_OUTSIDE_SENTINEL", to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape-dir"), withDestinationURL: temporary)
        let repo = root.appendingPathComponent("repo")
        try write("let initial = true\n", to: repo.appendingPathComponent("src/feature.swift"))
        _ = try git(repo, ["init", "-q"])
        _ = try git(repo, ["add", "src/feature.swift"])
        _ = try git(repo, ["commit", "-qm", "Initial fixture"])
        try write("let staged = true\n", to: repo.appendingPathComponent("src/feature.swift"))
        _ = try git(repo, ["add", "src/feature.swift"])
        try write("let unstaged = true\n", to: repo.appendingPathComponent("src/feature.swift"))
        try write("let untracked = true\n", to: repo.appendingPathComponent("src/odd name.swift"))
        try write("DO_NOT_READ_SECRET_SENTINEL", to: repo.appendingPathComponent(".env.md"))
        _ = try git(repo, ["add", ".env.md"])
        let unborn = root.appendingPathComponent("unborn")
        try write("No commits yet.\n", to: unborn.appendingPathComponent("README.md"))
        _ = try git(unborn, ["init", "-q"])
        let store = ProjectStore(root: temporary.appendingPathComponent("runtime"))
        let profile = try store.create(name: "Alpha", root: root), other = try store.create(name: "Beta", root: beta)
        let duplicate = try store.create(name: "Same root", root: root.appendingPathComponent("nested/.."))
        try require(duplicate.id == profile.id, "canonical duplicate root must reopen existing project")
        _ = try store.rename(id: profile.id, name: "Renamed alpha")
        try require(try store.profile(id: profile.id).name == "Renamed alpha", "rename preserves identity")
        try store.archive(id: profile.id)
        try require(try store.list().count == 1, "archived project is hidden")
        let restored = try store.create(name: "Restore", root: root)
        try require(restored.id == profile.id && !restored.archived, "adding archived root restores its identity")
        var reports = ["profiles: persistence, canonical duplicate root, rename, archive and restore"]

        let beforeStatus = try git(repo, ["status", "--porcelain=v2", "-z"])
        let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        let first = try await ProjectSourceCollector.collect(profile: profile, generationID: UUID(), deadline: Date().addingTimeInterval(30))
        let texts = first.excerpts.map(\.text).joined(separator: "\n"), paths = Set(first.excerpts.map { $0.source.relativePath })
        try require(paths.contains(".claude/history.md") && paths.contains(".Codex/handoff.md"), "hidden AI notes must be included; paths=\(paths.sorted()); omissions=\(first.manifest.omissions.map { $0.detail })")
        try require(paths.contains("nested/notes.md") && paths.contains("repo/src/feature.swift") && paths.contains("repo/src/odd name.swift"), "nested notes and changed/untracked code must be included")
        try require(!texts.contains("DO_NOT_READ"), "excluded and out-of-root content leaked into corpus or Git diff")
        try require(first.manifest.omissions.contains { $0.reason == .outsideRoot }, "symlink omission must be visible")
        try require(first.manifest.git.count == 2, "parent folder must discover nested repositories")
        try require(first.manifest.git.contains { $0.head == nil && !$0.detached && $0.stable }, "unborn repo is a stable no-commit snapshot")
        try require(texts.contains("+let staged = true") && texts.contains("+let unstaged = true"), "staged and unstaged diffs must stay distinct")
        try require(texts.contains("src/odd name.swift"), "NUL-delimited untracked paths preserve spaces")
        try require(try git(repo, ["status", "--porcelain=v2", "-z"]) == beforeStatus, "preparation changed repository status")
        try require(try Data(contentsOf: repo.appendingPathComponent(".git/index")) == indexBefore, "preparation modified Git index")
        reports.append("sources: scoped hidden notes, symlinks, exclusions, nested/unborn Git, staged/unstaged/untracked evidence; repository unchanged")
        var capped = profile; capped.limits.maxRepositories = 1; capped.limits.maxGitBytes = 20
        let cappedSources = try await ProjectSourceCollector.collect(profile: capped, generationID: UUID(), deadline: Date().addingTimeInterval(30))
        try require(cappedSources.manifest.omissions.contains { $0.reason == .limit && $0.detail.contains("repository-count") }, "repository overflow must be visible")
        try require(cappedSources.manifest.omissions.contains { $0.reason == .limit && $0.detail.contains("patch byte budget") }, "exhausted patch budget must be visible")
        let metadataOnly = temporary.appendingPathComponent("MetadataOnly")
        try fm.createDirectory(at: metadataOnly, withIntermediateDirectories: true)
        _ = try git(metadataOnly, ["init", "-q"])
        let metadataProfile = try store.create(name: "Metadata only", root: metadataOnly)
        let metadataPreparation = ProjectPreparation(store: store, synthesis: { _, _ in throw ProjectFailure("Metadata-only input should never reach a model.") })
        metadataPreparation.prepare(metadataProfile)
        try await until { !metadataPreparation.isPreparing }
        try require(metadataPreparation.error?.contains("Git metadata alone is insufficient") == true, "Git metadata alone must not establish context readiness")
        reports.append("coverage: repository and patch-budget overflow are explicit; Git-only folders cannot report context ready")

        let oldID = first.excerpts.first { $0.source.relativePath == "nested/notes.md" }!.source.id
        try write("Nested decision was revised.\n", to: root.appendingPathComponent("nested/notes.md"))
        let refreshed = try await ProjectSourceCollector.collect(profile: profile, generationID: UUID(), deadline: Date().addingTimeInterval(30))
        try require(refreshed.excerpts.first { $0.source.relativePath == "nested/notes.md" }?.source.id != oldID, "source changes must invalidate evidence IDs")
        _ = try git(repo, ["checkout", "--detach", "-q"])
        let detached = await GitCollector.collect(root: repo, scope: root, deadline: Date().addingTimeInterval(15))
        try require(detached.detached && detached.branch == nil && detached.head != nil, "detached state must differ from unborn")
        var small = other; small.limits.maxFileBytes = 25
        try write(String(repeating: "🙂", count: 50), to: beta.appendingPathComponent("emoji.md"))
        let clipped = try await ProjectSourceCollector.collect(profile: small, generationID: UUID(), deadline: Date().addingTimeInterval(15))
        try require(clipped.excerpts.contains { $0.source.truncated && $0.text.utf8.count <= 25 }, "UTF-8 truncation must remain valid and marked")
        reports.append("refresh: content hashes change with source edits; detached HEAD and UTF-8 truncation remain explicit")

        let selected = ProjectPacketBuilder.select(refreshed.excerpts, byteLimit: 2_000)
        try require(selected.reduce(0) { $0 + $1.text.utf8.count + 300 } <= 2_000, "selected packet exceeds byte budget")
        let result = try result(ProjectPacketBuilder.prompt(project: profile, excerpts: selected, manifest: refreshed.manifest))
        let packet = try ProjectPacketBuilder.packet(text: result.text, model: result.receipt, project: profile, manifest: refreshed.manifest, excerpts: selected)
        let allIDs = Set(refreshed.excerpts.map { $0.source.id })
        let corpus = refreshed.excerpts + selected.filter { !allIDs.contains($0.source.id) }
        var manifest = refreshed.manifest; manifest.sources = corpus.map(\.source)
        try store.publish(packet: packet, manifest: manifest, excerpts: corpus)
        try require(try store.latest(for: profile.id)?.id == packet.id, "complete packet pointer was not published")
        try require(try store.excerpts(for: packet).count == corpus.count, "corpus must round trip")
        do { try store.publish(packet: packet, manifest: manifest, excerpts: corpus); throw ProjectFailure("Immutable packet was overwritten.") }
        catch let error as ProjectFailure { try require(error.message == "Prepared packets are immutable.", "unexpected immutable publication failure") }
        // One overrunning claim is omitted with a coverage note; the supported claim still publishes.
        var mixed = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as! [String: Any]
        var mixedClaims = mixed["claims"] as! [[String: Any]]
        var overrun = mixedClaims[0]; overrun["key"] = "overrun"; overrun["quotes"] = []
        mixedClaims.append(overrun); mixed["claims"] = mixedClaims
        var second = mixedClaims[0]; second["key"] = "second"
        mixedClaims.insert(second, at: 1); mixed["claims"] = mixedClaims
        mixed["topics"] = [["key": "kept", "title": "Kept", "claimKeys": ["documented", "second"], "priority": "attention", "reason": "Supported."],
                           ["key": "both", "title": "Both", "claimKeys": ["documented", "overrun"], "priority": "attention", "reason": "Mixed."]]
        mixed["summaryClaimKeys"] = ["documented", "overrun"]
        let partial = try ProjectPacketBuilder.packet(text: String(decoding: try JSONSerialization.data(withJSONObject: mixed), as: UTF8.self),
            model: result.receipt, project: profile, manifest: refreshed.manifest, excerpts: selected)
        try require(partial.claims.count == 2 && partial.topics.map(\.key) == ["kept"]
                    && partial.coverageNotes.contains { $0.contains("1 prepared claim(s) were omitted") && $0.contains("overrun") },
                    "a failing claim must be omitted and named; topics that lost a claim are dropped")
        mixed["claims"] = [mixedClaims[0], overrun, { var o = overrun; o["key"] = "overrun2"; return o }()]
        mixed["topics"] = []; mixed["summaryClaimKeys"] = []
        do { _ = try ProjectPacketBuilder.packet(text: String(decoding: try JSONSerialization.data(withJSONObject: mixed), as: UTF8.self),
                 model: result.receipt, project: profile, manifest: refreshed.manifest, excerpts: selected); throw ProjectFailure("Mostly unsupported packet accepted.") }
        catch let error as ProjectFailure { try require(error.message.hasPrefix("2 of 3 prepared claims failed"), "a mostly invalid packet must fail") }
        var invalid = packet.claims; invalid[0].quotes = ["not present in supplied source"]
        do { try PacketValidator.validateClaims(invalid, excerpts: corpus); throw ProjectFailure("Invalid quote accepted.") }
        catch let error as ProjectFailure { try require(error.message.contains("unknown source") || error.message.contains("quote not present"), "invalid citation must be rejected") }
        let broken = temporary.appendingPathComponent("not-a-directory")
        try write("file", to: broken)
        do { try ProjectStore(root: broken).checkWritable(); throw ProjectFailure("Disk failure accepted.") }
        catch { try require(!(error is ProjectFailure), "storage failure must propagate") }
        reports.append("packets: bounded selection, exact citations, atomic pointer, immutable generation, corpus round trip and disk failure")

        let success = ProjectPreparation(store: store, synthesis: { prompt, _ in try Self.result(prompt) })
        success.prepare(other)
        try await until { !success.isPreparing }
        try require(success.error == nil && success.packet?.projectID == other.id, "fake synthesis failed to publish active project")
        let gate = ProjectTestSynthesis()
        let switched = ProjectPreparation(store: store, synthesis: { prompt, _ in try await gate.run(prompt) })
        switched.prepare(profile)
        try await until { await gate.count == 1 }
        let originalGeneration = switched.generationID
        switched.prepare(other)
        try await until { await gate.count == 2 }
        await gate.releaseAll()
        try await until { !switched.isPreparing }
        try require(switched.packet?.projectID == other.id && switched.error == nil, "late old-project completion replaced active project")
        try require(!fm.fileExists(atPath: store.packetDirectory(projectID: profile.id, generationID: originalGeneration!).path), "cancelled generation reached disk")
        let cancelledGate = ProjectTestSynthesis()
        let cancelled = ProjectPreparation(store: store, synthesis: { prompt, _ in try await cancelledGate.run(prompt) })
        cancelled.prepare(profile)
        try await until { await cancelledGate.count == 1 }
        let cancelledGeneration = cancelled.generationID!
        cancelled.cancel(); await cancelledGate.releaseAll()
        try await Task.sleep(for: .milliseconds(30))
        try require(!cancelled.isPreparing && !fm.fileExists(atPath: store.packetDirectory(projectID: profile.id, generationID: cancelledGeneration).path), "late cancelled result published")
        let deadlineGate = ProjectTestSynthesis()
        let timed = ProjectPreparation(store: store, deadlineLimit: 0.8, synthesis: { prompt, _ in try await deadlineGate.run(prompt) })
        timed.prepare(other)
        let timedGeneration = timed.generationID!
        try await until { await deadlineGate.count == 1 }
        try await until { !timed.isPreparing }
        await deadlineGate.releaseAll()
        try await Task.sleep(for: .milliseconds(30))
        try require(timed.error?.contains("deadline") == true && !fm.fileExists(atPath: store.packetDirectory(projectID: other.id, generationID: timedGeneration).path), "deadline must terminate and fence late publication")
        reports.append("coordinator: offline success, project-switch race, cancellation and terminal deadline; late results never publish")
        let mutationGate = ProjectTestSynthesis()
        let changing = ProjectPreparation(store: store, synthesis: { prompt, _ in try await mutationGate.run(prompt) })
        changing.prepare(other)
        let changingGeneration = changing.generationID!
        try await until { await mutationGate.count == 1 }
        try write("The beta review has changed during inference.\n", to: beta.appendingPathComponent("README.md"))
        await mutationGate.releaseAll()
        try await until { !changing.isPreparing }
        try require(changing.error?.contains("source changed") == true && !fm.fileExists(atPath: store.packetDirectory(projectID: other.id, generationID: changingGeneration).path), "source mutation during inference published stale context")
        reports.append("mutation fence: source edits during inference prevent publication")
        _ = try store.relocate(id: profile.id, to: beta)
        try require(try store.latest(for: profile.id) == nil, "relocation must invalidate prior-root packet")
        reports.append("relocation: old-root context is not reused")
        return reports
    }
}

/// Intentionally ignores task cancellation to exercise generation fencing.
private actor ProjectTestSynthesis {
    private var pending: [(String, CheckedContinuation<ModelResult, Error>)] = []
    var count: Int { pending.count }
    func run(_ prompt: String) async throws -> ModelResult {
        try await withCheckedThrowingContinuation { pending.append((prompt, $0)) }
    }
    func releaseAll() {
        let items = pending; pending = []
        for (prompt, continuation) in items {
            do { continuation.resume(returning: try ProjectWorkflowTests.result(prompt)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}
