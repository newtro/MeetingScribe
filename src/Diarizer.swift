import AVFoundation
import FluidAudio
import Foundation

/// Speaker diarization: NVIDIA Nemotron 3 Diarization (streaming Sortformer, up to 8 speakers per channel),
/// run on-device through FluidAudio's Core ML port. The model is bundled in the app — no download, no network.
///
/// One Core ML model is shared by both channels; all inference runs on one serial queue, never the capture queue.
/// At the `fast32` preset each channel costs well under 1% of real time on the Neural Engine.
final class DiarizationEngine: @unchecked Sendable {
    static let shared = DiarizationEngine()
    /// 2.88 s latency (2.56 s chunk + 0.32 s look-ahead). Beats the 1.04 s `low` profile on AMI (DER 9.53 vs 9.75,
    /// speaker-count accuracy 94% vs 75%) at a fraction of the per-call cost; finals rarely arrive sooner anyway.
    static let config = Nemotron3Config.fast32
    static var modelDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("Nemotron3", isDirectory: true) }

    let queue = DispatchQueue(label: "Diarization", qos: .userInitiated)
    private var loadTask: Task<Nemotron3Models, Error>?

    /// Loads once per process; later calls share the result (or the failure).
    func models() async throws -> Nemotron3Models {
        let task: Task<Nemotron3Models, Error> = queue.sync {
            if let loadTask { return loadTask }
            let t = Task.detached(priority: .userInitiated) { () throws -> Nemotron3Models in
                guard let dir = Self.modelDirectory else {
                    throw Nemotron3Error.modelLoadFailed("no app resources directory")
                }
                return try await Nemotron3Models.load(config: Self.config, directory: dir)
            }
            loadTask = t
            return t
        }
        return try await task.value
    }
}

// Holds an MLModel plus reused I/O buffers; safe to pass around because every call runs on DiarizationEngine.queue.
extension Nemotron3Models: @retroactive @unchecked Sendable {}

/// Per-channel streaming diarizer. Fed exactly the buffers the channel's SpeechAnalyzer gets (including silence
/// padding), so output frame `i` is analyzer time `i × 10 ms` and a final's `result.range` indexes it directly.
///
/// Labels are arrival-order per channel and per session: R1…R8 for REMOTE, L1…L8 for LOCAL. They are not identities.
final class ChannelDiarizer: @unchecked Sendable {
    let channel: Channel
    private let engine: DiarizationEngine
    private var queue: DispatchQueue { engine.queue }

    // Diarization-queue-only state.
    private var diarizer: Nemotron3Diarizer?
    private var disabled = false
    private var backlog: [Float] = []               // 16 kHz audio received before the model finished loading
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var probs: [Float] = []                 // [frame * 8 + speaker], frames from `probsStart`
    private var probsStart = 0
    private var framesDone = 0                      // 10 ms frames emitted so far
    private var finished = false
    private var pending: [Request] = []

    private struct Request {
        let start: Double, end: Double
        let deadline: DispatchTime
        let done: @Sendable (String?) -> Void
    }

    static let frameSeconds = 0.01
    static let speakers = 8
    /// How long a final may wait for the diarizer to cover its time range before it is written unlabeled.
    static let maxWait: TimeInterval = 4
    /// Keep 10 minutes of frame probabilities; finals never lag further than that.
    static let keepFrames = 60_000

    var onError: (@Sendable (String) -> Void)?

    init(channel: Channel, engine: DiarizationEngine = .shared) {
        self.channel = channel
        self.engine = engine
    }

    /// Starts loading the model. Audio fed before it is ready is backlogged, so the timeline stays aligned.
    func start() {
        Task { [self] in
            do {
                let models = try await engine.models()
                queue.async { [self] in
                    guard !disabled, !finished else { return }  // stopped before the model was ready
                    let d = Nemotron3Diarizer(config: DiarizationEngine.config, models: models)
                    diarizer = d
                    d.appendAudio(backlog)
                    backlog = []
                    process()
                }
            } catch {
                queue.async { [self] in disable("model load failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Called on the capture queue with a buffer already handed to the analyzer. Only reads it (the analyzer
    /// never mutates its input); conversion and inference happen on the diarization queue.
    func feed(_ buf: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !disabled, !finished, let samples = convert(buf), !samples.isEmpty else { return }
            if let diarizer {
                diarizer.appendAudio(samples)
                process()
            } else {
                backlog += samples
            }
        }
    }

    /// Resolves the speaker for analyzer time `start..<end` (seconds). Calls back on the diarization queue once
    /// the diarizer has covered the range, or after `maxWait` with whatever is known (nil if nothing).
    func label(start: Double, end: Double, done: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            pending.append(Request(start: start, end: max(end, start), deadline: .now() + Self.maxWait, done: done))
            resolvePending(force: disabled || finished)
            queue.asyncAfter(deadline: .now() + Self.maxWait + 0.05) { [self] in resolvePending(force: false) }
        }
    }

    /// Flushes the tail and answers every outstanding request. Call after the channel's transcriber has finished.
    func finish() {
        queue.sync {
            finished = true
            flush()
        }
    }

    // MARK: - Diarization queue

    private func flush() {
        if let diarizer, !disabled {
            do { append(try diarizer.finishStream()) } catch { disable("flush: \(error.localizedDescription)") }
        }
        resolvePending(force: true)
    }

    private func process() {
        guard let diarizer else { return }
        do {
            append(try diarizer.processBufferedAudio())
        } catch {
            disable("inference failed: \(error.localizedDescription)")
            return
        }
        resolvePending(force: false)
    }

    private func append(_ results: [Nemotron3ChunkResult]) {
        for r in results {
            probs += r.probabilities.prefix(r.frameCount * Self.speakers)
            framesDone += r.frameCount
        }
        let excess = (framesDone - probsStart) - Self.keepFrames
        if excess > Self.keepFrames / 4 {
            probs.removeFirst(excess * Self.speakers)
            probsStart += excess
        }
    }

    /// Answers requests in arrival order so finals are never reordered by labeling.
    private func resolvePending(force: Bool) {
        while let r = pending.first {
            let covered = Double(framesDone) * Self.frameSeconds >= r.end
            guard covered || force || .now() >= r.deadline else { return }
            pending.removeFirst()
            r.done(speaker(start: r.start, end: r.end))
        }
    }

    /// Majority speaker over the range, weighting each active frame by its probability.
    private func speaker(start: Double, end: Double) -> String? {
        let s = Self.speakers
        let first = max(Int((start / Self.frameSeconds).rounded(.down)), probsStart)
        let last = min(Int((end / Self.frameSeconds).rounded(.up)), framesDone)
        guard last > first else { return nil }
        var weight = [Float](repeating: 0, count: s)
        for f in first..<last {
            let base = (f - probsStart) * s
            for k in 0..<s where probs[base + k] > 0.5 { weight[k] += probs[base + k] }
        }
        guard let (k, w) = weight.enumerated().max(by: { $0.element < $1.element }), w > 0 else { return nil }
        return (channel == .remote ? "R" : "L") + String(k + 1)
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> [Float]? {
        let inFormat = buf.format
        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converter?.primeMethod = .none
            converterInputFormat = inFormat
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / inFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let p = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }

    private func disable(_ why: String) {
        guard !disabled else { return }
        disabled = true
        diarizer = nil
        backlog = []
        onError?("speaker labels off (\(channel.label)): \(why)")
        resolvePending(force: true)
    }
}
