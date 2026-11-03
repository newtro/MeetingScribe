import Foundation

/// Capture → two transcribers (+ a diarizer per channel) → session files. No UI dependencies; used by the app
/// and by --selftest.
@available(macOS 26.0, *)
final class Recorder: @unchecked Sendable {
    private let capture = AudioCapture()
    private var remote: ChannelTranscriber?
    private var local: ChannelTranscriber?
    private var diarizers: [ChannelDiarizer] = []
    private(set) var store: SessionStore?
    private var echo = EchoFilter(emit: { _ in })
    private let eventQueue = DispatchQueue(label: "Recorder.speechEvents")
    private var events: [UUID: SpeechEvent] = [:]
    private(set) var speechStatus: [Channel: String] = [:]

    var onFinal: (@Sendable (Utterance) -> Void)?
    var onVolatile: (@Sendable (Channel, String) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onSpeechEvent: (@Sendable (SpeechEvent) -> Void)?
    var onSpeechStatus: (@Sendable (Channel, SpeechEngine, String) -> Void)?

    var bufferCounts: (remote: Int, local: Int) { (capture.remoteBuffers, capture.localBuffers) }

    func start(locale: Locale) async throws -> SessionStore {
        let start = Date()
        let requestedEngine = SpeechEngine.selected
        let store = try SessionStore(start: start)
        self.store = store
        store.onWriteError = { [weak self] message in self?.onError?(message) }
        echo = EchoFilter(emit: { [weak self] u in
            store.append(u)
            self?.resolve(u, dropped: false)
            self?.onFinal?(u)
        }, drop: { [weak self] u in self?.resolve(u, dropped: true) })

        do {
        let r = try await ChannelTranscriber.make(channel: .remote, locale: locale, engine: requestedEngine, wallStart: start)
        remote = r
        let l = try await ChannelTranscriber.make(channel: .local, locale: locale, engine: requestedEngine, wallStart: start)
        local = l
        for t in [r, l] {
            // Each final waits (bounded) for its speaker label, then goes through the echo filter as before.
            let d = ChannelDiarizer(channel: t.channel)
            d.onError = { [weak self] msg in self?.onError?(msg) }
            d.start()
            diarizers.append(d)
            t.onAudio = { d.feed($0) }
            t.onSpeechEvent = { [weak self] event in
                guard let self else { return }
                self.eventQueue.async {
                    self.events[event.id] = event
                    self.onSpeechEvent?(event)
                }
            }
            t.onFinal = { [echo] u, start, end in
                d.label(start: start, end: end) { spk in
                    var u = u
                    u.spk = spk
                    echo.submit(u)
                }
            }
            t.onVolatile = { [weak self] ch, text in self?.onVolatile?(ch, text) }
            t.onError = { [weak self] ch, msg in self?.onError?("\(ch.label) transcriber: \(msg)") }
            try await t.start(wallStart: start)
            speechStatus[t.channel] = t.status
            onSpeechStatus?(t.channel, t.engine, t.status)
        }
        remote = r
        local = l

        capture.onRemote = { r.feed($0) }
        capture.onLocal = { l.feed($0) }
        capture.onStopped = { [weak self] msg in self?.onError?("Capture stopped: \(msg)") }
            try await capture.start()
        } catch {
            await remote?.finish()
            await local?.finish()
            for d in diarizers { d.finish() }
            diarizers = []
            echo.flush()
            eventQueue.sync { events.removeAll() }
            remote = nil; local = nil
            capture.onRemote = nil; capture.onLocal = nil; capture.onStopped = nil
            store.close()
            self.store = nil
            // Don't leave an empty session folder behind for a start that never recorded.
            if (try? FileManager.default.contentsOfDirectory(atPath: store.dir.path))?
                .allSatisfy({ (try? FileManager.default.attributesOfItem(atPath: store.dir.appendingPathComponent($0).path)[.size] as? Int) == 0 }) == true {
                try? FileManager.default.removeItem(at: store.dir)
            }
            throw error
        }
        return store
    }

    func stop() async {
        await capture.stop()
        async let a: Void = remote?.finish() ?? ()
        async let b: Void = local?.finish() ?? ()
        _ = await (a, b)
        for d in diarizers { d.finish() }  // labels any finals still waiting, before the echo filter flushes
        diarizers = []
        echo.flush()
        eventQueue.sync { events.removeAll() }
        remote = nil
        local = nil
        capture.onRemote = nil; capture.onLocal = nil; capture.onStopped = nil
        store?.close()
        store = nil
    }

    private func resolve(_ utterance: Utterance, dropped: Bool) {
        eventQueue.async { [self] in
            guard let previous = events.removeValue(forKey: utterance.id) else { return }
            onSpeechEvent?(SpeechEvent(id: previous.id, revision: previous.revision + 1,
                channel: previous.channel, t: previous.t, start: previous.start, end: previous.end,
                text: previous.text, final: true, retracted: dropped, speaker: utterance.spk))
        }
    }
}

/// Without headphones the mic hears the call, so LOCAL repeats REMOTE a beat later (or, depending on which
/// transcriber finalizes first, a beat earlier). LOCAL finals are held briefly and dropped if they closely
/// match a REMOTE final from the surrounding ±20s. REMOTE is never delayed or dropped.
final class EchoFilter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EchoFilter")
    private let emit: @Sendable (Utterance) -> Void
    private let drop: @Sendable (Utterance) -> Void
    private var recentRemote: [(Date, Set<String>)] = []
    private var pending: [UUID: Utterance] = [:]
    static let hold: TimeInterval = 8

    init(emit: @escaping @Sendable (Utterance) -> Void, drop: @escaping @Sendable (Utterance) -> Void = { _ in }) {
        self.emit = emit; self.drop = drop
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
    }

    private func isEcho(_ u: Utterance) -> Bool {
        let w = Self.words(u.text)
        return recentRemote.contains { (t, r) in
            guard abs(t.timeIntervalSince(u.t)) < 20 else { return false }
            if w.count < 3 { return !w.isEmpty && w.isSubset(of: r) }
            return Double(w.intersection(r).count) / Double(w.count) >= 0.6
        }
    }

    func submit(_ u: Utterance) {
        queue.async { [self] in
            if u.ch == .remote {
                recentRemote.append((u.t, Self.words(u.text)))
                recentRemote.removeAll { u.t.timeIntervalSince($0.0) > 60 }
                emit(u)
                for (id, p) in pending where isEcho(p) { pending[id] = nil; drop(p) }
                return
            }
            if isEcho(u) { drop(u); return }
            pending[u.id] = u
            queue.asyncAfter(deadline: .now() + Self.hold) { [self] in
                guard let p = pending.removeValue(forKey: u.id) else { return }
                if !isEcho(p) { emit(p) } else { drop(p) }
            }
        }
    }

    /// Emits anything still held (used on stop, after the transcribers have flushed).
    func flush() {
        queue.sync {
            for p in pending.values.sorted(by: { $0.t < $1.t }) {
                if isEcho(p) { drop(p) } else { emit(p) }
            }
            pending.removeAll()
        }
    }
}
