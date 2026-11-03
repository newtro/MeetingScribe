import AVFoundation
import FluidAudio
import Foundation

/// Synthetic only: no microphone, models, files, provider, or runtime library. Called by --workflowtest.
enum SpeechWorkflowTests {
    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        var timeline = SpeechTimeline(sampleRate: 16_000)
        let initial = timeline.reconcile(start: 0.25, count: 320)
        expect(initial.silence == 4000 && initial.trim == 0 && timeline.frames == 4320, "speech: initial channel offset")
        let contiguous = timeline.reconcile(start: 0.27, count: 320)
        expect(contiguous.silence == 0 && contiguous.trim == 0, "speech: contiguous timeline")
        let gap = timeline.reconcile(start: 0.49, count: 320)
        expect(gap.silence == 3200 && timeline.frames == 8160, "speech: PTS gap must pad both consumers")
        let duplicate = timeline.reconcile(start: 0.49, count: 320)
        expect(duplicate.trim == 320 && timeline.frames == 8160, "speech: duplicate PTS must not shift timeline")
        let overlap = timeline.reconcile(start: 0.50, count: 320)
        expect(overlap.trim == 160 && timeline.frames == 8320, "speech: overlapping buffer trim")

        var revision = SpeechRevisionState()
        let base = Date(timeIntervalSince1970: 100)
        let a = revision.event(channel: .remote, base: base, start: 1, end: 2, text: "We can", final: false)!
        expect(revision.event(channel: .remote, base: base, start: 1, end: 2, text: "We can", final: false) == nil,
               "speech: identical partial must not create revision")
        let b = revision.event(channel: .remote, base: base, start: 1, end: 3, text: "We cannot ship.", final: true)!
        expect(a.id == b.id && b.revision == a.revision + 1 && b.t == base.addingTimeInterval(1), "speech: final must preserve segment identity and time")
        let c = revision.event(channel: .remote, base: base, start: 4, end: 5, text: "Next", final: false)!
        let retract = revision.event(channel: .remote, base: base, start: 4, end: 5, text: "", final: true)!
        expect(c.id != b.id && retract.id == c.id && retract.retracted, "speech: empty corrected segment retracts")

        let echoes = SpeechTestValues<UUID>()
        let emitted = SpeechTestValues<UUID>()
        let filter = EchoFilter(emit: { emitted.append($0.id) }, drop: { echoes.append($0.id) })
        let local = Utterance(t: base, ch: .local, text: "The release needs approval")
        let remote = Utterance(t: base, ch: .remote, text: "The release needs approval")
        filter.submit(local); filter.submit(remote); filter.flush()
        expect(echoes.values == [local.id] && emitted.values == [remote.id], "speech: pending microphone echo must retract once")
        let nextLocal = Utterance(t: base, ch: .local, text: "The release needs approval")
        filter.submit(nextLocal); filter.flush()
        expect(echoes.values.contains(nextLocal.id), "speech: remote-first microphone echo must retract")
        let distinct = Utterance(t: base, ch: .local, text: "I will investigate latency")
        filter.submit(distinct); filter.flush()
        expect(emitted.values.contains(distinct.id), "speech: distinct local final survives stop flush")

        let mock = SpeechTestDecoder()
        let stream = UnifiedSpeechStream(model: mock, channel: .remote, base: base)
        let events = SpeechTestValues<SpeechEvent>()
        stream.emit = { events.append($0) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let voice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
        voice.frameLength = 320
        for i in 0..<320 { voice.floatChannelData![0][i] = 0.1 }
        do {
            try await stream.feed(voice)
            try await stream.finish()
            let values = events.values
            expect(values.count == 2 && !values[0].final && values[1].final && values[0].id == values[1].id,
                   "speech: stop must finalize the same provisional segment exactly once")
            expect(values.last?.text == "Do not ship.", "speech: stop must include decoder tail")
            expect(await mock.sampleCount == 320, "speech: flush must not duplicate samples")
            try await stream.finish()
            expect(events.values.count == values.count, "speech: repeated empty finish must not duplicate final")
        } catch { failures.append("speech: synthetic decoder failed: \(error)") }
        return failures
    }
}

private final class SpeechTestValues<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

private actor SpeechTestDecoder: UnifiedSpeechDecoding {
    private(set) var sampleCount = 0
    private var text = ""
    private var dirty = false
    func appendAudio(_ buffer: AVAudioPCMBuffer) { sampleCount += Int(buffer.frameLength); dirty = true }
    func processBufferedAudio() { if dirty { text = "Do not" } }
    func finish() -> String { if dirty { text = "Do not ship." }; return text }
    func reset() { dirty = false; text = "" }
    func consumeTokenTimings() -> [TokenTiming] { [] }
    func getPartialTranscript() -> String { text }
}
