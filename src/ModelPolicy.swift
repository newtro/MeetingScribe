import Foundation

enum ModelRole: String, CaseIterable, Codable, Sendable {
    case prepare, detect, cue, research, summary
}

struct ModelSetting: Codable, Sendable, Equatable {
    var modelID: String
    var effort: String
    var fallbackID: String?
}

struct ModelConfiguration: Codable, Sendable {
    var schemaVersion = 1
    var provider = "claudeCLI"
    var roles: [String: ModelSetting]
}

struct ModelReceipt: Codable, Sendable {
    var requestedModel: String
    var resolvedModels: [String]
    var effort: String
    var effectiveEffort: String?
    var requestedSpeed: String
    var effectiveSpeed: String
    var inputTokens: Int?
    var outputTokens: Int?
    var elapsed: TimeInterval
    var fallbackFrom: String?
    var speedNote: String?

    init(requestedModel: String, resolvedModels: [String] = [], effort: String = "medium",
         effectiveEffort: String? = nil, requestedSpeed: String = "standard", effectiveSpeed: String = "unknown",
         inputTokens: Int? = nil, outputTokens: Int? = nil, elapsed: TimeInterval = 0, fallbackFrom: String? = nil, speedNote: String? = nil) {
        self.requestedModel = requestedModel; self.resolvedModels = resolvedModels; self.effort = effort
        self.effectiveEffort = effectiveEffort; self.requestedSpeed = requestedSpeed; self.effectiveSpeed = effectiveSpeed
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.elapsed = elapsed; self.fallbackFrom = fallbackFrom
        self.speedNote = speedNote
    }

    var description: String {
        let actual = resolvedModels.isEmpty ? "model unconfirmed" : resolvedModels.joined(separator: ", ")
        let speed = speedNote ?? (requestedSpeed == "fast" && effectiveSpeed == "unknown" ? "Fast requested; effective speed unknown" : "speed \(effectiveSpeed)")
        return "\(actual) · \(speed)" + (fallbackFrom == nil ? "" : " · fallback from \(fallbackFrom!)")
    }
}

struct ModelResult: Sendable { var text: String; var receipt: ModelReceipt }

enum ModelPolicy {
    private static let lock = NSLock()
    static var configurationURL: URL { Paths.root.appendingPathComponent("model-settings.json") }

    static func defaultSetting(for role: ModelRole) -> ModelSetting {
        switch role {
        case .detect: return ModelSetting(modelID: "claude-haiku-5-5", effort: "low", fallbackID: "claude-sonnet-5-5")
        case .cue, .summary: return ModelSetting(modelID: "claude-sonnet-5-5", effort: "medium", fallbackID: nil)
        case .prepare, .research: return ModelSetting(modelID: "claude-opus-5-5", effort: "medium", fallbackID: "claude-sonnet-5-5")
        }
    }

    static func setting(for role: ModelRole) -> ModelSetting {
        lock.withLock {
            guard let data = try? Data(contentsOf: configurationURL),
                  let config = try? JSONDecoder().decode(ModelConfiguration.self, from: data),
                  config.schemaVersion == 1, config.provider == "claudeCLI",
                  let setting = config.roles[role.rawValue], (try? validate(setting)) != nil else {
                return defaultSetting(for: role)
            }
            return setting
        }
    }

    static func validate(_ setting: ModelSetting) throws {
        func fullID(_ id: String) -> Bool {
            id.hasPrefix("claude-") && id.count <= 100 && id.contains(where: \.isNumber)
                && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        }
        guard fullID(setting.modelID), ["low", "medium", "high"].contains(setting.effort),
              setting.fallbackID.map(fullID) ?? true else {
            throw ClaudeCLI.Failure(message: "Use a full versioned Claude model ID and low, medium or high effort.")
        }
    }

    static func save(_ setting: ModelSetting, for role: ModelRole) throws {
        try validate(setting)
        try lock.withLock {
            var config = (try? Data(contentsOf: configurationURL)).flatMap { try? JSONDecoder().decode(ModelConfiguration.self, from: $0) }
                ?? ModelConfiguration(roles: [:])
            config.roles[role.rawValue] = setting
            try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configurationURL, options: .atomic)
        }
    }
}

enum ModelRunner {
    struct ProviderFailure: Error, LocalizedError {
        var modelUnavailable: Bool
        var message: String
        var errorDescription: String? { message }
    }

    /// No tools, customization discovery, implicit role defaults, or persisted CLI conversation.
    static func arguments(setting: ModelSetting, fast: Bool, schema: [String: Any]?) throws -> [String] {
        try ModelPolicy.validate(setting)
        let settings: [String: Any] = ["fastMode": fast, "effortLevel": setting.effort, "switchModelsOnFlag": false]
        let settingsJSON = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--safe-mode", "--restricted",
                    "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands", "--no-chrome",
                    "--tools", "", "--model", setting.modelID, "--effort", setting.effort, "--settings", settingsJSON]
        if let schema { args += ["--json-schema", String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)] }
        return args
    }

    static var environment: [String: String] {
        var env = ClaudeCLI.environment
        // Keep authentication/provider routing, but prevent inherited role and effort overrides.
        for key in Array(env.keys) where key.hasPrefix("ANTHROPIC_DEFAULT_") ||
            ["ANTHROPIC_MODEL", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_SUBAGENT_MODEL", "MAX_THINKING_TOKENS",
             "CLAUDE_CODE_FAST_MODE", "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SYSTEM_PROMPT"].contains(key) {
            env.removeValue(forKey: key)
        }
        env["CLAUDE_CODE_SAFE_MODE"] = "1"
        return env
    }

    static func run(role: ModelRole, prompt: String, timeout: TimeInterval, fast: Bool = false,
                    schema: [String: Any]? = nil) async throws -> ModelResult {
        try Task.checkCancellation()
        let started = Date(), deadline = started.addingTimeInterval(timeout)
        let setting = ModelPolicy.setting(for: role)
        let requestedFast = fast && role == .research && setting.modelID.hasPrefix("claude-opus-")
        // A fresh neutral directory avoids parent project discovery as well as shared temp files.
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingScribe-Inference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        func invoke(_ chosen: ModelSetting, fast: Bool) async throws -> ModelResult {
            let runner = ClaudeCLI.Run(environment: environment)
            do {
                let raw = try await runner.run(args: arguments(setting: chosen, fast: fast, schema: schema),
                                               cwd: cwd, stdin: prompt, deadline: deadline, stdoutLimit: 1_048_576)
                return try parse(raw.stdout, setting: chosen, fast: fast, elapsed: Date().timeIntervalSince(started), requiresJSON: schema != nil)
            } catch let failure as ClaudeCLI.Failure {
                // Claude can encode an explicit model-unavailable error and exit nonzero.
                // Inspect only structured error metadata; never fallback on exit status alone.
                if let output = failure.stdout {
                    do { _ = try parse(output, setting: chosen, fast: fast, elapsed: Date().timeIntervalSince(started), requiresJSON: schema != nil) }
                    catch let provider as ProviderFailure { throw provider }
                    catch { }
                }
                throw failure
            }
        }
        do {
            var result = try await invoke(setting, fast: requestedFast)
            if fast && !requestedFast {
                result.receipt.requestedSpeed = "fast"
                result.receipt.speedNote = "Fast unavailable for this role/model; standard requested"
            }
            return result
        }
        catch let failure as ProviderFailure where failure.modelUnavailable && setting.fallbackID != nil {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw failure }
            let fallback = ModelSetting(modelID: setting.fallbackID!, effort: setting.effort, fallbackID: nil)
            var result = try await invoke(fallback, fast: false)
            result.receipt.fallbackFrom = setting.modelID
            result.receipt.requestedModel = setting.modelID
            result.receipt.requestedSpeed = requestedFast ? "fast" : "standard"
            if requestedFast { result.receipt.speedNote = "Fast unavailable on fallback; standard requested" }
            return result
        }
    }

    static func parse(_ stdout: String, setting: ModelSetting, fast: Bool, elapsed: TimeInterval,
                      requiresJSON: Bool) throws -> ModelResult {
        var final: [String: Any]?
        var models = Set<String>()
        for line in stdout.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "result" { final = object }
            if let message = object["message"] as? [String: Any], let model = message["model"] as? String { models.insert(model) }
        }
        guard let final else { throw ProviderFailure(modelUnavailable: false, message: "Provider returned no complete result.") }
        if final["is_error"] as? Bool == true {
            let detail = ((final["result"] as? String ?? "") + " " + (final["subtype"] as? String ?? "")).lowercased()
            let unavailable = ["model_not_found", "model not found", "model is not available", "model unavailable", "not have access to model", "model is not supported"].contains { detail.contains($0) }
            throw ProviderFailure(modelUnavailable: unavailable, message: unavailable ? "Requested model is unavailable." : "Provider rejected the request; no advice published.")
        }
        if let usage = final["modelUsage"] as? [String: Any] { models.formUnion(usage.keys) }
        let text: String
        if let structured = final["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            text = String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]), as: UTF8.self)
        } else { text = final["result"] as? String ?? "" }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderFailure(modelUnavailable: false, message: "Provider returned an empty result.")
        }
        if requiresJSON { _ = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        let usage = final["usage"] as? [String: Any]
        // Model IDs are authoritative response metadata. CLI currently does not reliably expose
        // effective effort/speed, so do not infer either from a requested setting or latency.
        let receipt = ModelReceipt(requestedModel: setting.modelID, resolvedModels: models.sorted(), effort: setting.effort,
                                   requestedSpeed: fast ? "fast" : "standard", effectiveSpeed: "unknown",
                                   inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int, elapsed: elapsed)
        return ModelResult(text: text, receipt: receipt)
    }
}
