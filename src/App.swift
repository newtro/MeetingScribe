import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

// MARK: - Model

@available(macOS 26.0, *)
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase { case idle, starting, recording, stopping }
    enum Blocker: Equatable { case screenRecording, microphone }
    enum Route: Hashable { case prep, live, brief(URL), session(URL) }

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
    @Published var route: Route = .prep
    @Published var sessions: [SessionInfo] = []

    // Recording
    @Published var phase: Phase = .idle
    @Published var startedAt: Date?
    @Published var utterances: [Utterance] = []
    @Published var volatile: [Channel: String] = [:]
    @Published var suggestions: [Suggestion] = []
    @Published var latestBatch: Set<UUID> = []
    @Published var modelStatus = "Checking speech model…"
    @Published var modelProgress: Double?
    @Published var modelReady = false
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

    func prepareModel() async {
        let loc = await SpeechModel.locale()
        locale = loc
        do {
            try await SpeechModel.ensureInstalled(locale: loc) { p, msg in
                Task { @MainActor in
                    AppModel.shared.modelProgress = p < 1 ? p : nil
                    AppModel.shared.modelStatus = msg
                }
            }
            modelReady = true
        } catch {
            modelStatus = "Speech model install failed: \(error.localizedDescription)"
        }
    }

    // MARK: Brief building

    func buildBrief() {
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
        if let briefURL { brief = briefURL }
        let typed = !draft.title.trimmingCharacters(in: .whitespaces).isEmpty || !draft.description.isEmpty
        var info = typed ? draft : ((hasBrief ? meta(forBrief: brief) : nil) ?? draft)
        if info.title.isEmpty { info.title = hasBrief ? Paths.briefName(brief) : "Meeting" }
        meeting = info
        Task { await start() }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        errorText = nil
        blocker = nil

        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            blocker = .microphone
            phase = .idle
            return
        }
        if !modelReady { await prepareModel() }
        guard modelReady, let locale else { phase = .idle; return }

        do {
            let store = try await recorder.start(locale: locale)
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
            meeting.brief = hasBrief ? brief.path : nil
            meeting.started = store.start
            meeting.ended = nil
            SessionFiles(dir: store.dir).save(meeting: meeting)
            phase = .recording
            route = .live
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording meeting")
            NSApp.dockTile.badgeLabel = "REC"
            advisorStatus = hasBrief ? "First check in \(Int(advisorInterval))s" : "No brief — advisor off"
            startAdvisorLoop()
            reloadSessions()
        } catch {
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
        guard phase == .recording else { return }
        phase = .stopping
        advisorLoop?.cancel()
        advisorLoop = nil
        await recorder.stop()
        volatile = [:]
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        NSApp.dockTile.badgeLabel = nil
        advisorStatus = "Stopped"
        phase = .idle
        guard let dir = sessionDir else { return }
        let files = SessionFiles(dir: dir)
        notesSave?.cancel()
        files.save(notes: notes)
        meeting.ended = Date()
        files.save(meeting: meeting)
        reloadSessions()
        route = .session(dir)
        meeting = MeetingInfo()
        draft = MeetingInfo()
        if UserDefaults.standard.object(forKey: Prefs.autoSummary) as? Bool ?? true, !utterances.isEmpty {
            summarize(dir)
        }
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
        guard hasBrief else { advisorStatus = "No brief — advisor off"; return }
        if advisorBusy { advisorStatus = "Still thinking — cycle skipped"; return }
        advisorBusy = true
        advisorStatus = "Checking…"
        let snapshot = utterances
        let outcome = await advisor.run(utterances: snapshot, names: speakerNames)
        advisorBusy = false
        let now = Fmt.clock.string(from: Date())
        switch outcome {
        case .items(let items):
            suggestions.insert(contentsOf: items, at: 0)
            latestBatch = Set(items.map(\.id))
            recorder.store?.appendSuggestions(Advisor.markdown(items))
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 26.0, *) else { return .terminateNow }
        return MainActor.assumeIsolated {
            guard AppModel.shared.phase == .recording else { return .terminateNow }
            Task { @MainActor in
                await AppModel.shared.stop()
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
        CommandGroup(replacing: .newItem) {
            Button("New Meeting") { m.route = .prep }
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
