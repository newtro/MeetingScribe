import AVFoundation
import CoreML
import FluidAudio
import Foundation

enum UnifiedSpeechAssets {
    static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
    static let config = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1)
    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("UnifiedSpeech") }
    static let required = [
        "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/weights/weight.bin",
        "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/model.mil",
        "parakeet_unified_decoder.mlmodelc/model.mil",
        "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil", "vocab.json",
        ".rev-" + revision
    ]
    static var available: Bool {
        guard let directory else { return false }
        return required.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func load() async throws -> StreamingUnifiedAsrManager {
        guard available, let directory else {
            throw NSError(domain: "MeetingScribe.Speech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled Unified 640 ms model is missing. Rebuild the app with its speech assets."])
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine // int8 must not route to the GPU
        let manager = StreamingUnifiedAsrManager(configuration: configuration, config: config, encoderPrecision: .int8)
        // Local-only API: never use fromHub/downloadAndLoad in a meeting.
        try await manager.loadModels(from: directory)
        return manager
    }
}

/// Preparation retains two independent, warmed decoder states for the two capture channels.
actor UnifiedSpeechPool {
    static let shared = UnifiedSpeechPool()
    private var prepared: [StreamingUnifiedAsrManager] = []
    private var preparing: Task<[StreamingUnifiedAsrManager], Error>?
    private(set) var failure: String?
    var isPrepared: Bool { prepared.count >= 2 }

    func prepare() async throws {
        if prepared.count >= 2 { return }
        let task: Task<[StreamingUnifiedAsrManager], Error>
        if let preparing { task = preparing }
        else {
            task = Task {
                var result: [StreamingUnifiedAsrManager] = []
                for _ in 0..<2 {
                    let model = try await UnifiedSpeechAssets.load()
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10_240)!
                    silence.frameLength = 10_240
                    memset(silence.floatChannelData![0], 0, 10_240 * MemoryLayout<Float>.size)
                    try await model.appendAudio(silence)
                    try await model.processBufferedAudio()
                    _ = try await model.finish()
                    try await model.reset()
                    result.append(model)
                }
                return result
            }
            preparing = task
        }
        do {
            let models = try await task.value
            if preparing != nil { prepared = models; preparing = nil }
            failure = nil
        } catch { preparing = nil; failure = error.localizedDescription; throw error }
    }

    func take() async throws -> StreamingUnifiedAsrManager {
        if preparing != nil { try await prepare() }
        if let model = prepared.popLast() { return model }
        if let failure {
            throw NSError(domain: "MeetingScribe.Speech", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return try await UnifiedSpeechAssets.load()
    }
}

/// One sequential consumer per channel. The decoder sees every sample exactly once. Silence endpoints
/// flush right context, commit text, then reset at the next sample (no replay and no retained raw audio).
protocol UnifiedSpeechDecoding: Sendable {
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws
    func processBufferedAudio() async throws
    func finish() async throws -> String
    func reset() async throws
    func consumeTokenTimings() async -> [TokenTiming]
    func getPartialTranscript() async -> String
}

extension StreamingUnifiedAsrManager: UnifiedSpeechDecoding {}

final class UnifiedSpeechStream {
    private let model: any UnifiedSpeechDecoding
    private(set) var frames: Int64 = 0
    private var epochStart = 0.0
    private var quietSamples = 0
    private var committedText = ""
    private var segmentStart: Double?
    private var lastTokenEnd = 0.0
    private var lastTokenStart = 0.0
    private var segmentTokenStart: Double?
    private var lastText = ""
    private var lastTextChangeFrame: Int64 = 0
    private var revisions = SpeechRevisionState()
    let channel: Channel
    var base: Date
    var emit: ((SpeechEvent) -> Void)?

    init(model: any UnifiedSpeechDecoding, channel: Channel, base: Date) {
        self.model = model; self.channel = channel; self.base = base
    }

    func feed(_ buffer: AVAudioPCMBuffer) async throws {
        let count = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            // Conservative acoustic endpoint. Individual quiet buffers accumulate; any voice resets it.
            // Never gate ingestion: quiet or softly spoken samples still go through the ASR model.
            var square: Float = 0
            for i in 0..<count { square += samples[i] * samples[i] }
            let rms = sqrt(square / Float(max(1, count)))
            quietSamples = rms < 0.004 ? quietSamples + count : 0
        }
        frames += Int64(count)
        try await model.appendAudio(buffer)
        try await model.processBufferedAudio()
        await observe(final: false)
        if quietSamples >= 12_800, frames - lastTextChangeFrame >= 6_400, !lastText.isEmpty {
            try await finishEpoch()
        } else if let start = segmentStart, Double(frames) / 16_000 - start >= 30 {
            // Long uninterrupted speech still gets durable segments. Commit only a completed prefix;
            // leave the final word provisional because a later subword token may extend it.
            let full = await model.getPartialTranscript()
            let tail = String(full.dropFirst(committedText.count))
            if let split = tail.lastIndex(where: { $0.isWhitespace }), split > tail.startIndex {
                let prefix = String(tail[..<split])
                publish(prefix, end: lastTokenStart, final: true)
                committedText += prefix
                segmentStart = nil
                segmentTokenStart = lastTokenStart
            }
        }
    }

    private func observe(final: Bool) async {
        let timings = await model.consumeTokenTimings()
        if let first = timings.first, segmentTokenStart == nil { segmentTokenStart = epochStart + first.startTime }
        if let last = timings.last {
            lastTokenStart = epochStart + last.startTime
            lastTokenEnd = epochStart + last.endTime
        }
        let full = await model.getPartialTranscript()
        if full.trimmingCharacters(in: .whitespacesAndNewlines) != lastText { lastTextChangeFrame = frames }
        let text = String(full.dropFirst(committedText.count))
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segmentStart = segmentStart ?? segmentTokenStart ?? epochStart
        }
        publish(text, end: min(Double(frames) / 16_000, lastTokenEnd), final: final)
        lastText = full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func publish(_ text: String, end: Double, final: Bool) {
        if let event = revisions.event(channel: channel, base: base,
                                       start: segmentStart ?? epochStart, end: end, text: text, final: final) {
            emit?(event)
        }
    }

    private func finishEpoch() async throws {
        _ = try await model.finish()
        await observe(final: true)
        try await model.reset()
        epochStart = Double(frames) / 16_000
        committedText = ""; lastText = ""; segmentStart = nil; segmentTokenStart = nil
        lastTokenEnd = epochStart; quietSamples = 0
    }

    func finish() async throws { try await finishEpoch() }

    /// Preserve text already observed if a later model call fails. The caller must also surface a
    /// capture coverage error; this is not a claim that failed/unprocessed audio was transcribed.
    func salvageObservedText() {
        publish(String(lastText.dropFirst(committedText.count)), end: lastTokenEnd, final: true)
        lastText = ""; committedText = ""
    }
}
