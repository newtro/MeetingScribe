import AppKit
import Combine
import Sparkle
import SwiftUI

/// Preferences belong to Sparkle, and are never reset when the application launches.
/// The activity gate is checked again at discovery and install time, because a meeting
/// may start after a scheduled request has already begun.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    @Published private(set) var isAvailable = false
    @Published private(set) var canCheckNow = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var activityBusy = false
    @Published private(set) var installationInProgress = false
    @Published private(set) var status = "Updates are available in the installed app."

    private var controller: SPUStandardUpdaterController?
    private weak var model: AppModel?
    private var subscriptions = Set<AnyCancellable>()
    private var deferredNotice = false

    func start(model: AppModel) {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        self.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.refreshState() }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in self?.refreshState() }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] _ in self?.refreshState() }.store(in: &subscriptions)
        updater.publisher(for: \.allowsAutomaticUpdates).sink { [weak self] _ in self?.refreshState() }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] in
            // ObservableObject emits before the value changes. Delegate gates below read the
            // actual model synchronously, not this delayed UI snapshot.
            DispatchQueue.main.async { self?.refreshState() }
        }.store(in: &subscriptions)
        isAvailable = true
        refreshState()
        controller.startUpdater()
    }

    private var mustDefer: Bool {
        guard let model else { return true }
        return UpdateSafetyPolicy.mustDefer(captureBusy: model.phase != .idle,
            preparationBusy: model.preparation.isPreparing || model.job?.running == true,
            summaryBusy: !model.summarizing.isEmpty)
    }

    private func refreshState() {
        guard let updater = controller?.updater else { return }
        activityBusy = mustDefer
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        canCheckNow = updater.canCheckForUpdates && !activityBusy && !installationInProgress
        if installationInProgress { status = "Installing update…" }
        else if activityBusy { status = "Updates wait until recording and meeting work finish." }
        else if deferredNotice { status = "An update is ready to review." }
        else if !automaticallyChecks { status = "Automatic update checks are off." }
        else if automaticallyDownloads { status = "Checks daily. Downloads can install when you quit." }
        else { status = "Checks daily. You choose when to download and install." }
        if deferredNotice && !activityBusy && !installationInProgress && updater.canCheckForUpdates {
            deferredNotice = false
            controller?.checkForUpdates(nil)
        }
    }

    func checkForUpdates() {
        guard !mustDefer, !installationInProgress, let controller, controller.updater.canCheckForUpdates else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        refreshState()
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refreshState()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Sparkle 2.10 checks this before installing/restarting, including a download
        // begun before the meeting. User-initiated Quit still follows AppDelegate's drain.
        !mustDefer
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Close the inverse race: after the final idle gate passes, a new capture must
        // not begin while Sparkle is arranging termination through its installer.
        installationInProgress = true
        refreshState()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationInProgress = false
        refreshState()
    }

    private func requireIdle() throws {
        guard !mustDefer else {
            throw NSError(domain: "MeetingScribe.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Updates are paused until recording and meeting work finish."])
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                         andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !mustDefer }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                              forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            if !handleShowingUpdate { deferredNotice = true; refreshState() }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { deferredNotice = false; refreshState() }
    }
}

enum UpdateSafetyPolicy {
    static func mustDefer(captureBusy: Bool, preparationBusy: Bool, summaryBusy: Bool) -> Bool {
        captureBusy || preparationBusy || summaryBusy
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updates = AppUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckNow)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var updates = AppUpdater.shared
    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                .disabled(!updates.isAvailable)
            Toggle("Download updates automatically", isOn: Binding(get: { updates.automaticallyDownloads }, set: updates.setAutomaticallyDownloads))
                .disabled(!updates.isAvailable || !updates.allowsAutomaticUpdates)
            CheckForUpdatesButton()
            Text(updates.status).font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum UpdaterWorkflowTests {
    @MainActor static func run() throws -> [String] {
        for phase in [AppModel.Phase.idle, .starting, .recording, .stopping] {
            let capture = phase != .idle
            for preparation in [false, true] {
                for summary in [false, true] {
                    let deferred = UpdateSafetyPolicy.mustDefer(captureBusy: capture, preparationBusy: preparation, summaryBusy: summary)
                    guard deferred != (!capture && !preparation && !summary) else {
                        throw ProjectFailure("Update activity policy permitted interruption or blocked idle updates.")
                    }
                }
            }
        }
        let selectors = ["updater:mayPerformUpdateCheck:error:", "updater:shouldProceedWithUpdate:updateCheck:error:",
                         "updaterShouldRelaunchApplication:", "updater:willInstallUpdate:", "updater:didAbortWithError:",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:"]
        for selector in selectors {
            guard AppUpdater.shared.responds(to: NSSelectorFromString(selector)) else {
                throw ProjectFailure("Sparkle safety delegate is not wired: " + selector)
            }
        }
        return ["Update activity gate blocks capture, preparation and summary; permits fully idle updates", "Sparkle Objective-C safety delegate selectors are connected"]
    }
}
