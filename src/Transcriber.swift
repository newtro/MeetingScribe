import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Owns a sample-clock timeline and one engine for one capture source. Conversion is serialized off the
/// capture callback; inference consumes a FIFO. The same normalized PCM reaches ASR and diarization.
@available(macOS 26.0, *)
final class ChannelTranscriber: @unchecked Sendable {
    let channel: Channel
    let engine: SpeechEngine
    let status: String
    private let format: AVAudioFormat
    private let apple: AppleSpeechStream?
    private let unified: UnifiedSpeechStream?
    private let queue: DispatchQueue
    private var input: AsyncStream<AVAudioPCMBuffer>?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var consumer: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var timeline: SpeechTimeline
    private var wallStart = Date()
    private var hostStart = 0.0
    private var ptsOrigin: Double?
    private var accepting = false

    var onFinal: (@Sendable (Utterance, Double, Double) -> Void)?
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onVolatile: (@Sendable (Channel, String) -> Void)?
    var onSpeechEvent: (@Sendable (SpeechEvent) -> Void)?
    var onError: (@Sendable (Channel, String) -> Void)?

    private init(channel: Channel, engine: SpeechEngine, status: String, format: AVAudioFormat,
                 apple: AppleSpeechStream? = nil, unified: UnifiedSpeechStream? = nil, base: Date) {
        self.channel = channel; self.engine = engine; self.status = status; self.format = format
        self.apple = apple; self.unified = unified; self.wallStart = base
        queue = DispatchQueue(label: "speech.input.\(channel.rawValue)", qos: .userInitiated)
        timeline = SpeechTimeline(sampleRate: format.sampleRate)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    static func make(channel: Channel, locale: Locale, engine requested: SpeechEngine = .selected,
                     wallStart: Date = Date()) async throws -> ChannelTranscriber {
        var fallbackReason: String?
        if requested == .unified {
            do {
                let model = try await UnifiedSpeechPool.shared.take()
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                           channels: 1, interleaved: false)!
                return ChannelTranscriber(channel: channel, engine: .unified, status: SpeechEngine.unified.label,
                    format: format, unified: UnifiedSpeechStream(model: model, channel: channel, base: wallStart), base: wallStart)
            } catch { fallbackReason = error.localizedDescription }
        }
        guard await SpeechModel.appleInstalled(locale: locale) else {
            throw NSError(domain: "MeetingScribe.Speech", code: 2, userInfo: [NSLocalizedDescriptionKey:
                (fallbackReason.map { "Unified unavailable: \($0). " } ?? "") + "Apple speech assets are not installed; prepare speech before recording."])
        }
        let apple = try await AppleSpeechStream.make(channel: channel, locale: locale)
        let status = fallbackReason.map { "Apple fallback — Unified unavailable: \($0)" } ?? SpeechEngine.apple.label
        return ChannelTranscriber(channel: channel, engine: .apple, status: status,
                                  format: apple.format, apple: apple, base: wallStart)
    }

    func start(wallStart: Date) async throws {
        self.wallStart = wallStart
        hostStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds - Date().timeIntervalSince(wallStart)
        if let apple {
            apple.emit = { [weak self] event in self?.publish(event) }
            apple.onError = { [weak self] message in self?.onError?(self?.channel ?? .remote, message) }
            try await apple.start(base: wallStart)
        }
        if let unified {
            // make/start normally receive the same session base; set it here for legacy --filetest callers.
            unified.base = wallStart
            unified.emit = { [weak self] event in self?.publish(event) }
            let pair = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
            input = pair.stream; continuation = pair.continuation
            consumer = Task { [weak self] in
                do {
                    for await buffer in pair.stream { try await unified.feed(buffer) }
                    try await unified.finish()
                } catch {
                    unified.salvageObservedText()
                    self?.queue.async { [weak self] in
                        self?.accepting = false
                        self?.continuation?.finish()
                        self?.continuation = nil
                        self?.input = nil
                    }
                    self?.onError?(self?.channel ?? .remote, "Unified inference stopped: \(error.localizedDescription). Stop and select Apple Speech to continue.")
                    // Report a failure explicitly; never silently skip audio and claim a complete transcript.
                }
            }
        }
        queue.sync { accepting = true }
    }

    private func publish(_ event: SpeechEvent) {
        onSpeechEvent?(event)
        onVolatile?(channel, event.final || event.retracted ? "" : event.text)
        if event.final, !event.retracted, !event.text.isEmpty {
            onFinal?(Utterance(id: event.id, t: event.t, ch: channel, text: event.text), event.start, event.end)
        }
    }

    func feed(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard accepting else { return }
            convertAndFeed(sample)
        }
    }

    private func convertAndFeed(_ sample: CMSampleBuffer) {
        guard sample.isValid, CMSampleBufferGetNumSamples(sample) > 0,
              let desc = CMSampleBufferGetFormatDescription(sample) else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: desc)
        let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count) else { return }
        source.frameLength = count
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                          into: source.mutableAudioBufferList) == noErr else { return }
        if converter == nil || converterInputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: format)
            converter?.primeMethod = .none
            converterInputFormat = sourceFormat
        }
        guard let converter else { onError?(channel, "Audio conversion unavailable"); return }
        let capacity = AVAudioFrameCount(Double(count) * format.sampleRate / sourceFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var used = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true; status.pointee = .haveData; return source
        }
        guard error == nil else { onError?(channel, "Audio conversion: \(error!.localizedDescription)"); return }
        guard output.frameLength > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if ptsOrigin == nil {
            // SCStream PTS is host time. Synthetic/file sources can use a different origin.
            ptsOrigin = pts.isFinite && abs(pts - hostStart) < 600 ? hostStart : pts
        }
        let start = ptsOrigin.map { pts - $0 } ?? Double(timeline.frames) / format.sampleRate
        guard !start.isFinite || start - Double(timeline.frames) / format.sampleRate < 600 else {
            onError?(channel, "Audio clock jumped more than ten minutes; capture must restart")
            return
        }
        let adjustment = timeline.reconcile(start: start, count: Int(output.frameLength))
        var silence = adjustment.silence
        while silence > 0 {
            let n = min(silence, Int(format.sampleRate / 50))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
            buffer.frameLength = AVAudioFrameCount(n)
            for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
            }
            deliver(buffer); silence -= n
        }
        if adjustment.trim > 0 {
            let remain = Int(output.frameLength) - adjustment.trim
            guard remain > 0 else { return }
            for b in UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList) {
                if let data = b.mData {
                    let stride = Int(b.mDataByteSize) / Int(output.frameLength)
                    memmove(data, data.advanced(by: adjustment.trim * stride), remain * stride)
                }
            }
            output.frameLength = AVAudioFrameCount(remain)
        }
        deliver(output)
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        onAudio?(buffer)
        if let apple { apple.feed(buffer) }
        else { continuation?.yield(buffer) }
    }

    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in accepting = false; continuation?.finish(); done.resume() }
        }
        await apple?.finish()
        _ = await consumer?.value
    }
}

@available(macOS 26.0, *)
private final class AppleSpeechStream {
    let format: AVAudioFormat
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Never>?
    private let channel: Channel
    var emit: ((SpeechEvent) -> Void)?
    var onError: ((String) -> Void)?

    private init(channel: Channel, transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.channel = channel; self.transcriber = transcriber; self.format = format
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    static func make(channel: Channel, locale: Locale) async throws -> AppleSpeechStream {
        let t = ChannelTranscriber.makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "MeetingScribe.Speech", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No Apple speech audio format"])
        }
        let stream = AppleSpeechStream(channel: channel, transcriber: t, format: format)
        try await stream.analyzer.prepareToAnalyze(in: format)
        return stream
    }

    func start(base: Date) async throws {
        results = Task { [self] in
            var segments: [Int64: SpeechRevisionState] = [:]
            do {
                for try await result in transcriber.results {
                    let start = result.range.start.seconds.isFinite ? max(0, result.range.start.seconds) : 0
                    let end = result.range.end.seconds.isFinite ? result.range.end.seconds : start
                    let key = Int64((start * 1000).rounded())
                    var state = segments[key] ?? SpeechRevisionState()
                    if let event = state.event(channel: channel, base: base, start: start, end: end,
                                               text: String(result.text.characters), final: result.isFinal) { emit?(event) }
                    if result.isFinal { segments.removeValue(forKey: key) }
                    else { segments[key] = state }
                }
            } catch { onError?(error.localizedDescription) }
        }
        try await analyzer.start(inputSequence: input)
    }
    func feed(_ buffer: AVAudioPCMBuffer) { continuation.yield(AnalyzerInput(buffer: buffer)) }
    func finish() async {
        continuation.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { onError?("Apple finalize: \(error.localizedDescription)") }
        _ = await results?.value
    }
}

@available(macOS 26.0, *)
enum SpeechModel {
    static func locale() async -> Locale {
        if SpeechEngine.selected == .unified { return Locale(identifier: "en-US") }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    }
    static func appleInstalled(locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
    static func readiness(locale: Locale) async -> SpeechReadiness {
        let requested = SpeechEngine.selected
        if requested == .unified, UnifiedSpeechAssets.available {
            let failure = await UnifiedSpeechPool.shared.failure
            if failure == nil {
                let warmed = await UnifiedSpeechPool.shared.isPrepared
                return SpeechReadiness(requested: requested, effective: .unified, ready: warmed,
                                       message: warmed ? "Unified ready for both channels" : "Unified bundled; preparation must warm both channels")
            }
        }
        let installed = await appleInstalled(locale: locale)
        return SpeechReadiness(requested: requested, effective: installed ? .apple : nil, ready: installed,
            message: installed ? (requested == .apple ? "Apple speech installed" : "Apple fallback; Unified unavailable")
                               : "Speech assets unavailable; build bundled models or install Apple assets before meeting")
    }
    static func prepare(locale: Locale, progress: @escaping @Sendable (Double, String) -> Void) async throws -> SpeechReadiness {
        let requested = SpeechEngine.selected
        var reason: String?
        if requested == .unified {
            do {
                progress(0, "Warming Unified speech for both channels…")
                try await UnifiedSpeechPool.shared.prepare()
                let message = SpeechEngine.unified.label + " ready"
                progress(1, message)
                return SpeechReadiness(requested: requested, effective: .unified, ready: true, message: message)
            } catch { reason = error.localizedDescription }
        }
        guard await appleInstalled(locale: locale) else {
            throw NSError(domain: "MeetingScribe.Speech", code: 4, userInfo: [NSLocalizedDescriptionKey:
                (reason.map { "Unified unavailable: \($0). " } ?? "") + "Apple assets are not installed. Speech preparation cannot download during a meeting."])
        }
        // Warm the analyzer without opening the microphone or starting capture.
        _ = try await AppleSpeechStream.make(channel: .remote, locale: locale)
        let message = reason.map { "Apple fallback ready — \($0)" } ?? "Apple speech ready"
        progress(1, message)
        return SpeechReadiness(requested: requested, effective: .apple, ready: true, message: message)
    }
    /// Compatibility entry point; preparation is now strictly local. No runtime model downloads.
    static func ensureInstalled(locale: Locale, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        _ = try await prepare(locale: locale, progress: progress)
    }
}
