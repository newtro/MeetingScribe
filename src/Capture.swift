import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct CapturePermissions: Equatable {
    let microphone: AVAuthorizationStatus
    let screenAudioGranted: Bool

    static var current: Self {
        Self(microphone: AVCaptureDevice.authorizationStatus(for: .audio),
             screenAudioGranted: CGPreflightScreenCaptureAccess())
    }

    static func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    var microphoneLabel: String {
        switch microphone {
        case .authorized: return "Microphone access granted"
        case .notDetermined: return "Microphone access not yet requested"
        case .denied: return "Microphone access denied"
        case .restricted: return "Microphone access restricted by macOS"
        @unknown default: return "Microphone access unavailable"
        }
    }

    var screenAudioLabel: String {
        screenAudioGranted ? "Screen & System Audio Recording access granted"
                           : "Screen & System Audio Recording access needed"
    }
}

/// One SCStream, two audio outputs: `.audio` = REMOTE (what the machine plays, i.e. the call),
/// `.microphone` = LOCAL (Scott).
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "capture.remote", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "capture.local", qos: .userInteractive)
    private let screenQueue = DispatchQueue(label: "capture.screen", qos: .background)

    var onRemote: ((CMSampleBuffer) -> Void)?
    var onLocal: ((CMSampleBuffer) -> Void)?
    var onStopped: (@Sendable (String) -> Void)?

    /// Buffer counters, for diagnostics.
    private(set) var remoteBuffers = 0
    private(set) var localBuffers = 0

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetingScribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 1
        // Video is required by SCStream; keep it as close to free as possible.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        cfg.queueDepth = 3
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            remoteBuffers += 1
            onRemote?(sampleBuffer)
        case .microphone:
            localBuffers += 1
            onLocal?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }
}
