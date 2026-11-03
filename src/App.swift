import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import Combine

// MARK: - Model

@available(macOS 26.0, *)
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase { case idle, starting, recording, stopping }
    enum Blocker: Equatable { case screenRecording, microphone }
    enum Route: Hashable { case projects, project(UUID), prep, live, brief(URL), session(URL) }

    /// A brief being written or revised by Claude.
    struct BuildJob: Equatable {
        var target: URL?                 // nil while building a new brief
        var refining: Bool
        var steps: [String] = []
        var started = Date()
        var error: String?
        var running: Bool { error == nil }
    }

    // Navigation
    @Published var route: Route = .projects
    @Published var sessions: [SessionInfo] = []
    @Published var projects: [ProjectProfile] = []
    @Published var selectedProjectID: UUID?
    @Published var persistenceError: String?
    let projectStore = ProjectStore()
    let preparation = ProjectPreparation()
    let live = LiveMeetingCoordinator()
    private var observers = Set<AnyCancellable>()
    private var recordingID: UUID?
    private var startingCapture = false
    private var terminating = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    // Recording
    @Published var phase: Phase = .idle {
        didSet {
            guard phase != .starting, phase != .stopping else { return }
            let waiters = lifecycleWaiters
            lifecycleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    @Published var startedAt: Date?
    @Published var utterances: [Utterance] = []
    @Published var volatile: [Channel: String] = [:]
    @Published var suggestions: [Suggestion] = []
    @Published var latestBatch: Set<UUID> = []
    @Published var modelStatus = "Checking speech model…"
    @Published var modelProgress: Double?
    @Published var modelReady = false
    @Published var diarizationReady = false
    @Published var diarizationStatus = "Speaker model not prepared"
    private var preparingSpeech = false
    private(set) var preparedSpeechEngine: SpeechEngine?
    private var speechPreparationID: UUID?
    @Published var advisorBusy = false
    @Published var advisorStatus = "Advisor idle"
    @Published var blocker: Blocker?
    @Published var errorText: String?
    @Published var sessionDir: URL?
    @Published var meeting = MeetingInfo()
    @Published var speakerNames: [String: String] = [:]
    @Published var highlights: [Highlight] = []
    @Published var notes = "" { didSet { scheduleNotesSave() } }

    // Briefs
    @Published var briefs: [URL] = []
    @Published var brief: URL = Paths.context { didSet { advisor.setContext(brief); UserDefaults.standard.set(brief.path, forKey: "brief") } }
    @Published var draft = MeetingInfo()
    @Published var job: BuildJob?

    // Summaries
    @Published var summarizing: Set<URL> = []
    @Published var summaryErrors: [URL: String] = [:]
    /// Bumped whenever a session's files change on disk, so open views reload.
    @Published var sessionRevision = 0

    private let recorder = Recorder()
    private let advisor = Advisor()
    private var builder: BriefBuilder?
    private var locale: Locale?
    private var advisorLoop: Task<Void, Never>?
    private var notesSave: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    var isRecording: Bool { phase == .recording }
    var hasBrief: Bool { FileManager.default.fileExists(atPath: brief.path) }

    init() {
        recorder.onFinal = { u in Task { @MainActor in AppModel.shared.utterances.append(u) } }
        recorder.onVolatile = { ch, t in Task { @MainActor in AppModel.shared.volatile[ch] = t } }
        recorder.onError = { msg in Task { @MainActor in AppModel.shared.errorText = msg } }
        Task { await prepareModel() }
        reloadBriefs()
        reloadSessions()
        reloadProjects()
        preparation.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.preparationChanged() }
        }.store(in: &observers)
        live.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
    }

    // MARK: Library

    /// Briefs and sessions are plain files, so the lists are refreshed whenever the app comes forward.
    func reloadBriefs() {
        briefs = Paths.briefs()
        let saved = UserDefaults.standard.string(forKey: "brief").map { URL(fileURLWithPath: $0) }
        if let saved, briefs.contains(saved) {
            if brief != saved { brief = saved }
        } else if let first = briefs.first, !briefs.contains(brief) || UserDefaults.standard.string(forKey: "brief") == nil {
            brief = first
        }
        advisor.setContext(brief)
    }

    func reloadSessions() {
        sessions = SessionInfo.all()
    }

    func meta(forBrief url: URL) -> MeetingInfo? { JSON.read(MeetingInfo.self, from: Paths.metaURL(forBrief: url)) }

    // MARK: Speech model

    func speechEngineChanged() {
        modelReady = false
        preparedSpeechEngine = nil
        locale = nil
        guard phase == .idle || (phase == .starting && !startingCapture) else { return }
        modelStatus = "Preparing selected speech engine…"
        Task { await prepareModel(allowStarting: true) }
    }

    func prepareModel(allowStarting: Bool = false) async {
        guard !terminating, !startingCapture, phase == .idle || (allowStarting && phase == .starting) else { return }
        while preparingSpeech {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
        guard !terminating, !startingCapture, !Task.isCancelled, phase == .idle || (allowStarting && phase == .starting) else { return }
        if modelReady, preparedSpeechEngine == SpeechEngine.selected { return }
        preparingSpeech = true
        defer { preparingSpeech = false; speechPreparationID = nil; modelProgress = nil }
        while !terminating, !Task.isCancelled, phase == .idle || phase == .starting {
            let requested = SpeechEngine.selected
            let generation = UUID()
            speechPreparationID = generation
            modelReady = false
            preparedSpeechEngine = nil
            locale = nil
            let loc = await SpeechModel.locale()
            guard !terminating, !Task.isCancelled else { return }
            if requested != SpeechEngine.selected { continue }
            do {
                let readiness = try await SpeechModel.prepare(locale: loc) { [weak self] p, msg in
                    Task { @MainActor in
                        guard let self, self.speechPreparationID == generation,
                              requested == SpeechEngine.selected else { return }
                        self.modelProgress = p < 1 ? p : nil
                        self.modelStatus = msg
                    }
                }
                guard !terminating, !Task.isCancelled else { return }
                if requested != SpeechEngine.selected || readiness.requested != requested { continue }
                modelStatus = readiness.message
                do {
                    try await DiarizationEngine.shared.prepare()
                    diarizationReady = true
                    diarizationStatus = "Nemotron 3 speaker labels ready"
                } catch {
                    diarizationReady = false
                    diarizationStatus = "Speaker labels unavailable: \(error.localizedDescription)"
                }
                guard !terminating, !Task.isCancelled else { return }
                if requested != SpeechEngine.selected { continue }
                locale = loc
                preparedSpeechEngine = requested
                modelReady = readiness.ready
                return
            } catch {
                if requested != SpeechEngine.selected { continue }
                modelStatus = "Speech model preparation failed: \(error.localizedDescription)"
                return
            }
        }
    }

    // MARK: Brief building

    func buildBrief() {
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "MeetingScribe is updating. Try again after it reopens."
            return
        }
        guard job?.running != true else { return }
        var info = draft
        if info.title.trimmingCharacters(in: .whitespaces).isEmpty { info.title = "Meeting" }
        job = BuildJob(target: nil, refining: false)
        let b = BriefBuilder()
        builder = b
        Task {
            do {
                let text = try await b.build(info) { e in Task { @MainActor in AppModel.shared.log(e) } }
                try? FileManager.default.createDirectory(at: Paths.briefMeta, withIntermediateDirectories: true)
                let url = Paths.newBriefURL(title: info.title)
                try text.write(to: url, atomically: true, encoding: .utf8)
                JSON.write(info, to: Paths.metaURL(forBrief: url))
                job = nil
                reloadBriefs()
                brief = url
                route = .brief(url)
            } catch is CancellationError {
                job = nil
            } catch {
                job?.error = error.localizedDescription
            }
            builder = nil
        }
    }

    /// Asks Claude to revise a brief in place. The previous text is kept in contexts/.meta/<name>.prev.md.
    func refine(_ url: URL, instruction: String) {
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "MeetingScribe is updating. Try again after it reopens."
            return
        }
        guard job?.running != true, !instruction.trimmingCharacters(in: .whitespaces).isEmpty,
              let current = try? String(contentsOf: url, encoding: .utf8) else { return }
        var info = meta(forBrief: url) ?? MeetingInfo()
        if info.title.isEmpty { info.title = Paths.briefName(url) }
        job = BuildJob(target: url, refining: true)
        let b = BriefBuilder()
        builder = b
        Task {
            do {
                let text = try await b.build(info, current: current, instruction: instruction) { e in
                    Task { @MainActor in AppModel.shared.log(e) }
                }
                try? FileManager.default.createDirectory(at: Paths.briefMeta, withIntermediateDirectories: true)
                try? current.write(to: Paths.briefMeta.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".prev.md"),
                                   atomically: true, encoding: .utf8)
                try text.write(to: url, atomically: true, encoding: .utf8)
                job = nil
                sessionRevision += 1
            } catch is CancellationError {
                job = nil
            } catch {
                job?.error = error.localizedDescription
            }
            builder = nil
        }
    }

    func cancelBuild() {
        builder?.cancel()
        if job?.running == false { job = nil }
    }

    private func log(_ e: BriefBuilder.Event) {
        guard job != nil else { return }
        switch e {
        case .step(let s): job?.steps.append(s)
        case .thinking(let s): job?.steps.append("· " + s)
        }
    }

    // MARK: Recording

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        default: break
        }
    }

    /// Starts with the given brief (or the selected one). Meeting details come from the brief's metadata when it
    /// was built here, else from the New Meeting form.
    func startMeeting(with briefURL: URL? = nil) {
        guard phase == .idle, !terminating else { return }
        if briefURL == nil, selectedProjectID != nil { startProjectMeeting(); return }
        selectedProjectID = nil
        if let briefURL { brief = briefURL }
        let typed = !draft.title.trimmingCharacters(in: .whitespaces).isEmpty || !draft.description.isEmpty
        var info = typed ? draft : ((hasBrief ? meta(forBrief: brief) : nil) ?? draft)
        if info.title.isEmpty { info.title = hasBrief ? Paths.briefName(brief) : "Meeting" }
        meeting = info
        Task { await start() }
    }

    func start() async {
        guard phase == .idle, !terminating else { return }
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "An application update is finishing. Start your meeting after the app reopens."
            return
        }
        phase = .starting
        let token = UUID()
        recordingID = token
        errorText = nil
        persistenceError = nil
        blocker = nil
        recorder.onFinal = { [weak self] u in Task { @MainActor in
            guard let self, self.recordingID == token else { return }
            self.utterances.append(u)
        } }
        recorder.onVolatile = { [weak self] ch, text in Task { @MainActor in
            guard let self, self.recordingID == token else { return }
            self.volatile[ch] = text
        } }
        recorder.onSpeechEvent = { [weak self] event in Task { @MainActor in
            guard let self, self.recordingID == token, self.selectedProjectID != nil else { return }
            self.live.ingest(event)
        } }
        recorder.onSpeechStatus = { [weak self] channel, _, status in Task { @MainActor in
            guard let self, self.recordingID == token else { return }
            self.modelStatus = "\(channel.label): \(status)"
        } }

        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            blocker = .microphone
            recordingID = nil
            phase = .idle
            return
        }
        guard !terminating else { recordingID = nil; phase = .idle; return }
        if !modelReady || preparedSpeechEngine != SpeechEngine.selected { await prepareModel(allowStarting: true) }
        guard !terminating, modelReady, preparedSpeechEngine == SpeechEngine.selected,
              let locale else { recordingID = nil; phase = .idle; return }

        do {
            startingCapture = true
            let store = try await recorder.start(locale: locale)
            startingCapture = false
            store.onWriteError = { [weak self] message in Task { @MainActor in
                guard let self, self.recordingID == token else { return }
                self.persistenceError = message
            } }
            utterances = []
            volatile = [:]
            suggestions = []
            latestBatch = []
            speakerNames = [:]
            highlights = []
            notesSave?.cancel()
            notes = ""
            sessionDir = store.dir
            startedAt = store.start
            if meeting.title.isEmpty { meeting.title = hasBrief ? Paths.briefName(brief) : "Meeting" }
            // Preparation may have completed while capture was starting. Pin one snapshot for both
            // the session metadata and live advice, with no await between these assignments.
            let packet = currentProjectPacket
            meeting.projectID = selectedProjectID
            meeting.preparedPacketID = packet?.id
            meeting.brief = selectedProjectID == nil ? (hasBrief ? brief.path : nil) : packet.map { projectStore.briefURL(projectID: $0.projectID, packetID: $0.id).path }
            meeting.started = store.start
            meeting.ended = nil
            SessionFiles(dir: store.dir).save(meeting: meeting)
            phase = .recording
            route = .live
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording meeting")
            NSApp.dockTile.badgeLabel = "REC"
            if selectedProjectID != nil {
                live.onCue = { [weak self, weak store] cue in
                    guard let self, self.recordingID == token, self.isRecording else { return }
                    let suggestion = cue.suggestion
                    self.suggestions.insert(suggestion, at: 0)
                    self.latestBatch = [suggestion.id]
                    store?.appendSuggestions(Advisor.markdown([suggestion]))
                }
                live.start(sessionID: token, sessionDir: store.dir, packet: packet)
                advisorStatus = "Listening"
            } else {
                advisorStatus = hasBrief ? "First check in \(Int(advisorInterval))s" : "No brief — advisor off"
                startAdvisorLoop()
            }
            reloadSessions()
        } catch {
            startingCapture = false
            recordingID = nil
            phase = .idle
            let ns = error as NSError
            if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
                blocker = .screenRecording
                CGRequestScreenCaptureAccess()
            } else {
                errorText = "Could not start: \(error.localizedDescription)"
            }
        }
    }

    func stop() async {
        // A second Stop or Quit joins the same startup/drain instead of returning early.
        while phase == .starting || phase == .stopping {
            await withCheckedContinuation { lifecycleWaiters.append($0) }
        }
        guard phase == .recording else { return }
        phase = .stopping
        defer {
            phase = .idle
            if !terminating, !modelReady || preparedSpeechEngine != SpeechEngine.selected {
                Task { await prepareModel() }
            }
        }
        live.stop()
        advisor.cancel()
        advisorLoop?.cancel()
        advisorLoop = nil
        await recorder.stop()
        recordingID = nil
        advisorBusy = false
        volatile = [:]
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        NSApp.dockTile.badgeLabel = nil
        advisorStatus = "Stopped"
        guard let dir = sessionDir else { return }
        let files = SessionFiles(dir: dir)
        // Recorder drains its queues before returning; use the durable finals even if their
        // MainActor display callbacks were still queued when the recording token closed.
        utterances = files.utterances
        notesSave?.cancel()
        files.save(notes: notes)
        meeting.ended = Date()
        files.save(meeting: meeting)
        reloadSessions()
        route = .session(dir)
        meeting = MeetingInfo()
        draft = MeetingInfo()
        if !terminating, UserDefaults.standard.object(forKey: Prefs.autoSummary) as? Bool ?? true, !utterances.isEmpty {
            summarize(dir)
        }
    }

    func prepareToTerminate() async {
        terminating = true
        await stop()
    }

    var advisorInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: Prefs.advisorInterval)
        return v >= 15 ? v : 45
    }

    private func startAdvisorLoop() {
        advisorLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.advisorInterval ?? 45))
                if Task.isCancelled { break }
                await self?.askNow()
            }
        }
    }

    func askNow() async {
        guard isRecording else { return }
        if selectedProjectID != nil { live.ask("What matters most right now? Suggest a useful question or next step grounded in this discussion."); return }
        guard hasBrief else { advisorStatus = "No brief — advisor off"; return }
        if advisorBusy { advisorStatus = "Still thinking — cycle skipped"; return }
        advisorBusy = true
        advisorStatus = "Checking…"
        let snapshot = utterances
        let token = recordingID
        let store = recorder.store
        let outcome = await advisor.run(utterances: snapshot, names: speakerNames)
        guard isRecording, recordingID == token else { return }
        advisorBusy = false
        let now = Fmt.clock.string(from: Date())
        switch outcome {
        case .items(let items):
            suggestions.insert(contentsOf: items, at: 0)
            latestBatch = Set(items.map(\.id))
            store?.appendSuggestions(Advisor.markdown(items))
            advisorStatus = "Last check \(now) — \(items.count) new"
        case .silent:
            advisorStatus = "Last check \(now) — nothing new"
        case .skipped(let why):
            advisorStatus = "Last check \(now) — skipped: \(why)"
        case .failed(let why):
            advisorStatus = "Last check \(now) — \(why)"
        }
    }

    // MARK: During the meeting

    func markMoment(note: String = "") {
        guard isRecording, let dir = sessionDir else { return }
        let h = Highlight(t: Date(), note: note)
        highlights.append(h)
        SessionFiles(dir: dir).append(highlight: h)
    }

    func updateHighlight(_ h: Highlight, note: String) {
        guard let dir = sessionDir, let i = highlights.firstIndex(of: h) else { return }
        highlights[i].note = note
        SessionFiles(dir: dir).rewrite(highlights: highlights)
    }

    /// Names a diarized speaker slot, live or after the fact. Stored in the session's speakers.json.
    func rename(_ spk: String, to name: String, in dir: URL) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = SessionFiles(dir: dir)
        var names = dir == sessionDir && isRecording ? speakerNames : files.speakers
        names[spk] = clean.isEmpty ? nil : clean
        files.save(speakers: names)
        if dir == sessionDir && isRecording { speakerNames = names }
        sessionRevision += 1
    }

    private func scheduleNotesSave() {
        guard isRecording, let dir = sessionDir else { return }
        notesSave?.cancel()
        let text = notes
        notesSave = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { SessionFiles(dir: dir).save(notes: text) }
        }
    }

    // MARK: After the meeting

    func summarize(_ dir: URL) {
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "MeetingScribe is updating. Try again after it reopens."
            return
        }
        guard !summarizing.contains(dir) else { return }
        summarizing.insert(dir)
        summaryErrors[dir] = nil
        let files = SessionFiles(dir: dir)
        let briefURL = files.meeting?.brief.map { URL(fileURLWithPath: $0) }
        Task {
            do {
                var text = try await Summarizer.summarize(files: files, briefURL: briefURL)
                // The summary opens with a suggested title; use it when the meeting has none, keep the body.
                if text.hasPrefix("# "), let nl = text.firstIndex(of: "\n") {
                    let suggested = text[text.index(text.startIndex, offsetBy: 2)..<nl].trimmingCharacters(in: .whitespaces)
                    text = String(text[nl...]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                    var info = files.meeting ?? MeetingInfo()
                    if info.title.isEmpty || info.title == "Meeting", !suggested.isEmpty {
                        info.title = suggested
                        files.save(meeting: info)
                    }
                }
                files.save(summary: text)
            } catch {
                summaryErrors[dir] = error.localizedDescription
            }
            summarizing.remove(dir)
            sessionRevision += 1
            reloadSessions()
        }
    }

    func export(_ dir: URL) {
        let info = sessions.first { $0.dir == dir } ?? SessionInfo.load(dir)
        let md = Export.markdown(files: SessionFiles(dir: dir), info: info)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "\(info?.title ?? "Meeting") \(dir.lastPathComponent.prefix(10)).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func copyTranscript(_ dir: URL) {
        let files = SessionFiles(dir: dir)
        let names = files.speakers
        let text = files.utterances.sorted { $0.t < $1.t }
            .map { "[\(Fmt.clock.string(from: $0.t))] \(Speakers.display($0, names: names)): \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func renameSession(_ dir: URL, title: String) {
        let files = SessionFiles(dir: dir)
        var info = files.meeting ?? MeetingInfo()
        info.title = title
        files.save(meeting: info)
        reloadSessions()
    }

    func openSessionFolder() {
        NSWorkspace.shared.open(sessionDir ?? Paths.sessions)
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start(model: AppModel.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 26.0, *) else { return .terminateNow }
        return MainActor.assumeIsolated {
            guard AppModel.shared.phase != .idle else { return .terminateNow }
            guard !terminationPending else { return .terminateLater }
            terminationPending = true
            Task { @MainActor in
                await AppModel.shared.prepareToTerminate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

struct MeetingScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("MeetingScribe", id: "main") {
            RootView().environmentObject(AppModel.shared)
        }
        .defaultSize(width: 1400, height: 860)
        .commands { MeetingCommands(m: AppModel.shared) }

        Window("Meeting prompter", id: "prompter") {
            PrompterPanel().environmentObject(AppModel.shared)
        }
        .defaultSize(width: 620, height: 600)

        MenuBarExtra {
            MenuBarMenu().environmentObject(AppModel.shared)
        } label: {
            MenuBarLabel().environmentObject(AppModel.shared)
        }

        Settings {
            SettingsView().frame(width: 520)
        }
    }
}

@available(macOS 26.0, *)
struct MeetingCommands: Commands {
    @ObservedObject var m: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(replacing: .newItem) {
            Button("Projects") { m.route = .projects }
                .keyboardShortcut("n")
                .disabled(m.isRecording)
        }
        CommandMenu("Meeting") {
            Button(m.isRecording ? "Stop Recording" : "Start Recording") {
                if m.isRecording { m.toggle() } else { m.startMeeting() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(m.phase == .starting || m.phase == .stopping)
            Button("Ask Advisor Now") { Task { await m.askNow() } }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!m.isRecording || m.advisorBusy)
            Button("Mark Moment") { m.markMoment() }
                .keyboardShortcut("b")
                .disabled(!m.isRecording)
            Divider()
            Button("Show Session Folder") { m.openSessionFolder() }
        }
    }
}

@available(macOS 26.0, *)
struct MenuBarLabel: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Image(systemName: m.isRecording ? "record.circle.fill" : "waveform.circle")
    }
}

@available(macOS 26.0, *)
struct MenuBarMenu: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if m.isRecording {
            Text("Recording — \(m.meeting.title)")
            Button("Mark Moment") { m.markMoment() }
            Button("Ask Advisor Now") { Task { await m.askNow() } }.disabled(m.advisorBusy)
            Button("Stop Recording") { m.toggle() }
        } else {
            Button("Start Recording\(m.hasBrief ? " — \(Paths.briefName(m.brief))" : "")") { m.startMeeting() }
                .disabled(m.phase != .idle)
            Button("New Meeting…") {
                m.route = .prep
                show()
            }
        }
        Divider()
        Button("Open MeetingScribe") { show() }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
