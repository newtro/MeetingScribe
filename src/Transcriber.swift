import AVFoundation
import CoreMedia
import Foundation
import Speech

/// One SpeechAnalyzer + SpeechTranscriber per channel. Fed CMSampleBuffers from the capture queue;
/// never blocks it — conversion is synchronous and cheap, input is handed off through an AsyncStream.
@available(macOS 26.0, *)
final class ChannelTranscriber: @unchecked Sendable {
    let channel: Channel
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?

    // Capture-queue-only state.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var firstPTS: Double?
    private var framesFed: Int64 = 0
    private var wallStart = Date()

    /// Final text plus its analyzer-timeline range in seconds (start, end), for speaker lookup.
    var onFinal: (@Sendable (Utterance, Double, Double) -> Void)?
    /// Every buffer handed to the analyzer, silence padding included, on the capture queue. Must not block.
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onVolatile: (@Sendable (Channel, String) -> Void)?
    var onError: (@Sendable (Channel, String) -> Void)?

    private init(channel: Channel, transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.channel = channel
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzerFormat = format
        (input, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange])
    }

    static func make(channel: Channel, locale: Locale) async throws -> ChannelTranscriber {
        let t = makeTranscriber(locale: locale)
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "MeetingScribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio format available for SpeechTranscriber"])
        }
        let ct = ChannelTranscriber(channel: channel, transcriber: t, format: fmt)
        try await ct.analyzer.prepareToAnalyze(in: fmt)
        return ct
    }

    func start(wallStart: Date) async throws {
        self.wallStart = wallStart
        let ch = channel
        resultsTask = Task { [transcriber, weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self?.onVolatile?(ch, "")
                        guard !text.isEmpty else { continue }
                        let offset = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
                        let end = result.range.end.seconds.isFinite ? result.range.end.seconds : offset
                        let base = self?.wallStart ?? Date()
                        let t = base.addingTimeInterval(offset)
                        self?.onFinal?(Utterance(t: t, ch: ch, text: text), offset, end)
                    } else {
                        self?.onVolatile?(ch, text)
                    }
                }
            } catch {
                self?.onError?(ch, "\(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: input)
    }

    /// Called on the capture queue.
    func feed(_ sbuf: CMSampleBuffer) {
        guard sbuf.isValid, CMSampleBufferGetNumSamples(sbuf) > 0,
              let desc = CMSampleBufferGetFormatDescription(sbuf) else { return }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sbuf))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sbuf, at: 0, frameCount: Int32(frames),
                                                                  into: inBuf.mutableAudioBufferList)
        guard status == noErr else { return }

        // Keep the analyzer timeline aligned with wall time: if the stream skipped (no audio delivered),
        // pad with silence so result.range maps back to real clock time.
        let pts = CMSampleBufferGetPresentationTimeStamp(sbuf).seconds
        if firstPTS == nil { firstPTS = pts; wallStart = Date() }
        if let first = firstPTS, pts.isFinite {
            let expected = Double(framesFed) / analyzerFormat.sampleRate
            let actual = pts - first
            let gap = actual - expected
            if gap > 0.25 && gap < 600 {
                yieldSilence(seconds: gap)
            }
        }

        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: analyzerFormat)
            converter?.primeMethod = .none
            converterInputFormat = inFormat
        }
        guard let converter else { return }
        let ratio = analyzerFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        if err != nil || out.frameLength == 0 { return }
        framesFed += Int64(out.frameLength)
        inputBuilder.yield(AnalyzerInput(buffer: out))
        onAudio?(out)
    }

    private func yieldSilence(seconds: Double) {
        var remaining = AVAudioFrameCount(seconds * analyzerFormat.sampleRate)
        let chunk = AVAudioFrameCount(analyzerFormat.sampleRate) // 1s buffers
        while remaining > 0 {
            let n = min(chunk, remaining)
            guard let buf = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: n) else { return }
            buf.frameLength = n
            let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
            for b in abl { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            framesFed += Int64(n)
            inputBuilder.yield(AnalyzerInput(buffer: buf))
            onAudio?(buf)
            remaining -= n
        }
    }

    /// Flushes remaining audio to final results, then stops.
    func finish() async {
        inputBuilder.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
            onError?(channel, "finalize: \(error.localizedDescription)")
        }
        _ = await resultsTask?.value
    }
}

@available(macOS 26.0, *)
enum SpeechModel {
    static func locale() async -> Locale {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return l }
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) { return l }
        return Locale(identifier: "en-US")
    }

    /// Ensures the on-device model for `locale` is installed. Reports 0...1 progress.
    static func ensureInstalled(locale: Locale, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let t = ChannelTranscriber.makeTranscriber(locale: locale)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            progress(1, "Speech model ready (\(locale.identifier))")
            return
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) else {
            progress(1, "Speech model ready (\(locale.identifier))")
            return
        }
        progress(0, "Downloading speech model…")
        let p = req.progress
        let poll = Task {
            while !Task.isCancelled {
                progress(p.fractionCompleted, "Downloading speech model… \(Int(p.fractionCompleted * 100))%")
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poll.cancel() }
        try await req.downloadAndInstall()
        progress(1, "Speech model ready (\(locale.identifier))")
    }
}
