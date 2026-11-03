import AppKit
import Foundation

/// Offline checks never construct AppModel or touch the real meeting library.
enum WorkflowTests {
    static func outputDirectory(_ path: String?) throws -> URL {
        let base = URL(fileURLWithPath: path ?? "build/verification", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let runtime = Paths.root.standardizedFileURL.resolvingSymlinksInPath().path
        guard base.path != runtime, !base.path.hasPrefix(runtime + "/") else { throw ProjectFailure("Test output must be outside the meeting library.") }
        let out = base.appendingPathComponent("check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    static func run(out: String?) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let directory = try outputDirectory(out)
                var failures = await SpeechWorkflowTests.run()
                do { _ = try await LiveAdviceTests.run() }
                catch { failures.append("Live advice: \(error.localizedDescription)") }
                do { _ = try await ProjectWorkflowTests.run() }
                catch { failures.append("Project workflow: \(error.localizedDescription)") }
                do { _ = try await PrompterWorkflowTests.run() }
                catch { failures.append("Native prompter: \(error.localizedDescription)") }
                do { _ = try UpdaterWorkflowTests.run() }
                catch { failures.append("Updater policy: \(error.localizedDescription)") }
                do { try contractCheck() }
                catch { failures.append("Archive contract: \(error.localizedDescription)") }
                let report: [String: Any] = ["passed": failures.isEmpty, "failures": failures,
                    "suites": ["speech timeline / revision / echo / flush", "advisor queue / provenance / cancellation", "project scopes / Git / preparation races", "archive format / legacy metadata", "native prompter anchor / takeover / resume", "updater activity gate / delegate selectors"],
                    "providerCalls": 0, "captureStarted": false]
                let url = directory.appendingPathComponent("report.json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
                print("Workflow checks: \(failures.isEmpty ? "PASS" : "FAIL") — \(url.path)")
                failures.forEach { print($0) }
                exit(failures.isEmpty ? 0 : 1)
            } catch { fputs("Workflow error: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func contractCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingScribe-contract-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SessionStore(start: date, sessionsRoot: dir)
        let text = "The connection works, but delivery has not been tested."
        store.append(Utterance(t: date, ch: .remote, text: text, spk: "R1"))
        store.appendSuggestions("## 12:00:00\n- ASK: Who owns the retest?\n")
        store.close()
        let raw = try Data(contentsOf: store.dir.appendingPathComponent("transcript.jsonl"))
        guard let line = try JSONSerialization.jsonObject(with: raw) as? [String: String],
              Set(line.keys) == Set(["t", "ch", "text", "spk"]), line["text"] == text, line["ch"] == "remote", line["spk"] == "R1" else {
            throw ProjectFailure("Finalized JSONL contract changed.")
        }
        let plain = try String(contentsOf: store.dir.appendingPathComponent("transcript.txt"), encoding: .utf8)
        guard plain == "[\(Fmt.clock.string(from: date))] REMOTE: \(text)\n" else { throw ProjectFailure("Plain transcript contract changed.") }
        let old = Data(#"{"title":"Old meeting","description":"","attendees":"","materials":[],"allowWeb":false}"#.utf8)
        let decoded = try JSONDecoder().decode(MeetingInfo.self, from: old)
        guard decoded.projectID == nil, decoded.preparedPacketID == nil else { throw ProjectFailure("Legacy metadata migration failed.") }
    }

    /// One real standard-mode preparation check, using an isolated app-data root.
    static func prepareProject(folder: String, out: String?) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let directory = try outputDirectory(out)
                let store = ProjectStore(root: directory.appendingPathComponent("runtime"))
                let root = URL(fileURLWithPath: folder, isDirectory: true)
                let project = try store.create(name: root.lastPathComponent, root: root)
                let preparation = ProjectPreparation(store: store)
                let began = Date()
                preparation.prepare(project)
                var last = ""
                while preparation.isPreparing {
                    if last != preparation.status { last = preparation.status; print(last) }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard let packet = preparation.packet, preparation.error == nil else { throw ProjectFailure(preparation.error ?? "No packet produced.") }
                let report: [String: Any] = ["passed": true, "elapsedSeconds": Date().timeIntervalSince(began),
                    "claims": packet.claims.count, "sources": preparation.manifest?.sources.count ?? 0,
                    "brief": store.briefURL(for: packet).path, "actualModels": packet.model.resolvedModels]
                let url = directory.appendingPathComponent("project-check.json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
                print("Project preparation PASS — \(url.path)"); exit(0)
            } catch { fputs("Project check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
}
