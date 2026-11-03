import Foundation

/// Advisory observations. Revisions replace earlier observations with the same ID; only the existing
/// onFinal/store path writes the archive. A retraction invalidates any advice based on microphone echo.
struct SpeechEvent: Sendable {
    let id: UUID
    let revision: Int
    let channel: Channel
    let t: Date
    let start: Double
    let end: Double
    let text: String
    let final: Bool
    let retracted: Bool
    let speaker: String?
}

enum SpeechEngine: String, CaseIterable, Sendable {
    case unified, apple
    static let preferenceKey = "speechEngine"
    static var selected: SpeechEngine {
        SpeechEngine(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .unified
    }
    var label: String { self == .unified ? "Parakeet Unified · English · 640 ms" : "Apple Speech" }
}

struct SpeechReadiness: Sendable {
    let requested: SpeechEngine
    let effective: SpeechEngine?
    let ready: Bool
    let message: String
}

/// Pure sample-clock reconciliation: pad missing audio and trim overlapping buffers rather than shifting
/// subsequent speech. Both ASR and the diarizer receive the resulting exact same buffers.
struct SpeechTimeline {
    let sampleRate: Double
    private(set) var frames: Int64 = 0

    mutating func reconcile(start: Double, count: Int) -> (silence: Int, trim: Int) {
        guard start.isFinite else { frames += Int64(count); return (0, 0) }
        let desired = max(0, Int64((start * sampleRate).rounded()))
        let delta = desired - frames
        // A couple of frames of rounding noise must not create artificial gaps.
        let silence = delta > 2 ? Int(delta) : 0
        let trim = delta < -2 ? min(count, Int(-delta)) : 0
        frames += Int64(silence + count - trim)
        return (silence, trim)
    }
}

/// Tracks one provisional segment; finalization retains its identity and advances a fresh segment.
struct SpeechRevisionState {
    private(set) var id = UUID()
    private(set) var revision = 0
    private(set) var text = ""

    mutating func event(channel: Channel, base: Date, start: Double, end: Double,
                        text: String, final: Bool) -> SpeechEvent? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final || cleaned != self.text else { return nil }
        guard !cleaned.isEmpty || !self.text.isEmpty else { return nil }
        revision += 1
        self.text = cleaned
        let e = SpeechEvent(id: id, revision: revision, channel: channel,
                            t: base.addingTimeInterval(start), start: start, end: max(start, end),
                            text: cleaned, final: final, retracted: cleaned.isEmpty, speaker: nil)
        if final { self = SpeechRevisionState() }
        return e
    }
}
