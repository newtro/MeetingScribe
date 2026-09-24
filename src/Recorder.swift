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

    var onFinal: (@Sendable (Utterance) -> Void)?
    var onVolatile: (@Sendable (Channel, String) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    var bufferCounts: (remote: Int, local: Int) { (capture.remoteBuffers, capture.localBuffers) }

    func start(locale: Locale) async throws -> SessionStore {
        let start = Date()
        let store = try SessionStore(start: start)
        self.store = store
        echo = EchoFilter(emit: { [weak self] u in
            store.append(u)
            self?.onFinal?(u)
        })

        let r = try await ChannelTranscriber.make(channel: .remote, locale: locale)
        let l = try await ChannelTranscriber.make(channel: .local, locale: locale)
        for t in [r, l] {
            // Each final waits (bounded) for its speaker label, then goes through the echo filter as before.
            let d = ChannelDiarizer(channel: t.channel)
            d.onError = { [weak self] msg in self?.onError?(msg) }
            d.start()
            diarizers.append(d)
            t.onAudio = { d.feed($0) }
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
        }
        remote = r
        local = l

        capture.onRemote = { r.feed($0) }
        capture.onLocal = { l.feed($0) }
        capture.onStopped = { [weak self] msg in self?.onError?("Capture stopped: \(msg)") }
        do {
            try await capture.start()
        } catch {
            await r.finish()
            await l.finish()
            for d in diarizers { d.finish() }
            diarizers = []
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
        remote = nil
        local = nil
        store?.close()
        store = nil
    }
}

/// Without headphones the mic hears the call, so LOCAL repeats REMOTE a beat later (or, depending on which
/// transcriber finalizes first, a beat earlier). LOCAL finals are held briefly and dropped if they closely
/// match a REMOTE final from the surrounding ±20s. REMOTE is never delayed or dropped.
final class EchoFilter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EchoFilter")
    private let emit: @Sendable (Utterance) -> Void
    private var recentRemote: [(Date, Set<String>)] = []
    private var pending: [UUID: Utterance] = [:]
    static let hold: TimeInterval = 8

    init(emit: @escaping @Sendable (Utterance) -> Void) { self.emit = emit }

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
                for (id, p) in pending where isEcho(p) { pending[id] = nil }
                return
            }
            if isEcho(u) { return }
            pending[u.id] = u
            queue.asyncAfter(deadline: .now() + Self.hold) { [self] in
                guard let p = pending.removeValue(forKey: u.id) else { return }
                if !isEcho(p) { emit(p) }
            }
        }
    }

    /// Emits anything still held (used on stop, after the transcribers have flushed).
    func flush() {
        queue.sync {
            for p in pending.values.sorted(by: { $0.t < $1.t }) where !isEcho(p) { emit(p) }
            pending.removeAll()
        }
    }
}
