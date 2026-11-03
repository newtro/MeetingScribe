import Foundation
import Combine
import AVFoundation
import CoreGraphics

enum ReadinessDimension: String, Codable, CaseIterable, Sendable {
    case context, sources, provider, storage, capturePermission, speech, diarization, audioSignalCheck
}
enum ReadinessLevel: String, Codable, Sendable { case unknown, checking, ready, limited, blocked }
struct ReadinessRecord: Codable, Sendable {
    var dimension: ReadinessDimension
    var state: ReadinessLevel
    var detail: String
    var checkedAt: Date
}
struct ReadinessSnapshot: Codable, Sendable {
    var checkedAt = Date()
    var generationID: UUID?
    var dimensions: [ReadinessRecord] = ReadinessDimension.allCases.map {
        ReadinessRecord(dimension: $0, state: .unknown, detail: "Not checked in this launch.", checkedAt: Date())
    }
    subscript(_ dimension: ReadinessDimension) -> ReadinessRecord? { dimensions.first { $0.dimension == dimension } }
    mutating func set(_ dimension: ReadinessDimension, state: ReadinessLevel, detail: String) {
        checkedAt = Date()
        let value = ReadinessRecord(dimension: dimension, state: state, detail: detail, checkedAt: checkedAt)
        if let index = dimensions.firstIndex(where: { $0.dimension == dimension }) { dimensions[index] = value } else { dimensions.append(value) }
    }
    var overall: String {
        if [ReadinessDimension.storage, .capturePermission, .speech].contains(where: { self[$0]?.state == .blocked }) { return "Capture setup required" }
        if [.context, .provider].contains(where: { self[$0]?.state == .blocked }) { return "Transcript only" }
        let required: [ReadinessDimension] = [.context, .sources, .provider, .storage, .capturePermission, .speech, .diarization]
        if required.contains(where: { self[$0]?.state == .checking || self[$0]?.state == .unknown }) { return "Readiness checks incomplete" }
        if required.allSatisfy({ self[$0]?.state == .ready }) { return "Ready to start" }
        return "Ready with limits"
    }
}

/// Local-only checks. Speech and shared diarizer readiness are supplied by the
/// owning capture pipeline; this never starts capture or loads a duplicate model.
@MainActor final class ReadinessCoordinator: ObservableObject {
    @Published var snapshot = ReadinessSnapshot()
    func prepare(project: ProjectProfile, generationID: UUID, store: ProjectStore = ProjectStore()) {
        snapshot = ReadinessSnapshot(generationID: generationID)
        do { try store.checkWritable(); snapshot.set(.storage, state: .ready, detail: "Application data directory is writable.") }
        catch { snapshot.set(.storage, state: .blocked, detail: error.localizedDescription) }
        let permissions = CapturePermissions.current
        snapshot.set(.capturePermission, state: permissions.screenAudioGranted && permissions.microphone == .authorized ? .ready : .blocked,
                     detail: permissions.microphoneLabel + ". " + permissions.screenAudioLabel + ".")
        snapshot.set(.provider, state: FileManager.default.isExecutableFile(atPath: ClaudeCLI.path) ? .checking : .blocked,
                     detail: "Provider readiness requires a successful model request; executable presence alone is insufficient.")
        snapshot.set(.context, state: .checking, detail: "Refreshing project context.")
        snapshot.set(.sources, state: .checking, detail: "Reading selected local sources; remote services are not refreshed.")
        snapshot.set(.audioSignalCheck, state: .unknown, detail: "No end-to-end audio signal check has run for this device route.")
    }
}
