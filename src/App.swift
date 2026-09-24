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
    @Published var briefs: [URL] = []
    @Published var brief: URL = Paths.context { didSet { advisor.setContext(brief); UserDefaults.standard.set(brief.path, forKey: "brief") } }

    private let recorder = Recorder()
    private let advisor = Advisor()
    private var locale: Locale?
    private var advisorLoop: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    var isRecording: Bool { phase == .recording }

    init() {
        recorder.onFinal = { u in Task { @MainActor in AppModel.shared.utterances.append(u) } }
        recorder.onVolatile = { ch, t in Task { @MainActor in AppModel.shared.volatile[ch] = t } }
        recorder.onError = { msg in Task { @MainActor in AppModel.shared.errorText = msg } }
        Task { await prepareModel() }
        reloadBriefs()
    }

    /// Briefs are plain files, so the list is refreshed whenever the app comes forward.
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

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        default: break
        }
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
            sessionDir = store.dir
            startedAt = Date()
            phase = .recording
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording meeting")
            NSApp.dockTile.badgeLabel = "REC"
            advisorStatus = "First check in 45s"
            startAdvisorLoop()
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
    }

    private func startAdvisorLoop() {
        advisorLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                if Task.isCancelled { break }
                await self?.askNow()
            }
        }
    }

    func askNow() async {
        guard isRecording else { return }
        if advisorBusy { advisorStatus = "Still thinking — cycle skipped"; return }
        advisorBusy = true
        advisorStatus = "Checking…"
        let snapshot = utterances
        let outcome = await advisor.run(utterances: snapshot)
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        WindowGroup("MeetingScribe") {
            if #available(macOS 26.0, *) {
                RootView().environmentObject(AppModel.shared)
            } else {
                Text("MeetingScribe needs macOS 26.").padding(40)
            }
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Views

enum Palette {
    static let remote = Color(red: 0.20, green: 0.62, blue: 0.86)
    static let local = Color(red: 0.95, green: 0.60, blue: 0.20)
    static let rec = Color(red: 0.86, green: 0.12, blue: 0.14)
    static func tag(_ k: SuggestionKind) -> Color {
        switch k {
        case .flag: return Color(red: 0.90, green: 0.12, blue: 0.12)
        case .ask: return Color(red: 0.22, green: 0.50, blue: 0.95)
        case .answer: return Color(red: 0.16, green: 0.66, blue: 0.36)
        case .note: return .gray
        }
    }
}

@available(macOS 26.0, *)
struct RootView: View {
    @EnvironmentObject var m: AppModel
    @AppStorage("suggestionFontSize") var fontSize: Double = 28

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(fontSize: $fontSize)
            if let b = m.blocker { PermissionBanner(blocker: b) }
            if let e = m.errorText {
                Text(e).font(.callout).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color.orange.opacity(0.85))
            }
            HSplitView {
                TranscriptPane()
                    .frame(minWidth: 320, idealWidth: 460)
                SuggestionsPane(fontSize: fontSize)
                    .frame(minWidth: 520, idealWidth: 900)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !m.isRecording { m.reloadBriefs() }
        }
        .navigationTitle(m.isRecording ? "● RECORDING — MeetingScribe" : "MeetingScribe")
    }
}

@available(macOS 26.0, *)
struct ControlBar: View {
    @EnvironmentObject var m: AppModel
    @Binding var fontSize: Double

    var body: some View {
        HStack(spacing: 16) {
            Button(action: m.toggle) {
                Label(m.isRecording ? "Stop" : (m.phase == .starting ? "Starting…" : "Start"),
                      systemImage: m.isRecording ? "stop.fill" : "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 110)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(m.isRecording ? .black.opacity(0.55) : Palette.rec)
            .disabled(m.phase == .starting || m.phase == .stopping)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            if m.isRecording {
                RecordingBadge()
                if let s = m.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(from: s, to: ctx.date))
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.modelStatus).font(.callout).foregroundStyle(.secondary)
                    if let p = m.modelProgress { ProgressView(value: p).frame(width: 220) }
                }
            }

            Spacer()

            Text(m.advisorStatus).font(.callout)
                .foregroundStyle(m.isRecording ? .white.opacity(0.9) : .secondary)
                .lineLimit(1)
            if m.advisorBusy { ProgressView().controlSize(.small) }
            Button {
                Task { await m.askNow() }
            } label: {
                Label("Ask now", systemImage: "sparkles").font(.title3.weight(.semibold))
            }
            .controlSize(.large)
            .disabled(!m.isRecording || m.advisorBusy)
            .keyboardShortcut(.return, modifiers: [.command])

            if !m.isRecording {
                Picker("", selection: Binding(get: { m.brief }, set: { m.brief = $0 })) {
                    ForEach(m.briefs, id: \.self) { u in Text(Paths.briefName(u)).tag(u) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .help("Which brief governs this meeting")
            } else {
                Text(Paths.briefName(m.brief))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.25)))
                    .help("Brief in use")
            }

            HStack(spacing: 2) {
                Button { fontSize = max(16, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    .keyboardShortcut("-", modifiers: [.command])
                Button { fontSize = min(56, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                    .keyboardShortcut("=", modifiers: [.command])
            }
            .help("Suggestion text size (⌘− / ⌘=)")
            Button(action: m.openSessionFolder) { Image(systemName: "folder") }
                .help("Open session folder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(m.isRecording ? Palette.rec : Color(nsColor: .controlBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: m.isRecording)
    }

    func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

struct RecordingBadge: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.white).frame(width: 14, height: 14)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("RECORDING · this meeting is being transcribed")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .onAppear { pulse = true }
    }
}

@available(macOS 26.0, *)
struct PermissionBanner: View {
    let blocker: AppModel.Blocker
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.lock.fill").font(.largeTitle)
            VStack(alignment: .leading, spacing: 6) {
                if blocker == .screenRecording {
                    Text("Screen & System Audio Recording permission is needed").font(.title3.bold())
                    Text("MeetingScribe captures call audio through ScreenCaptureKit. Open System Settings › Privacy & Security › Screen & System Audio Recording, turn on MeetingScribe (use + to add it from ~/Applications if it isn't listed), then quit and reopen MeetingScribe.")
                    Button("Open Screen & System Audio Recording settings") { AppModel.openScreenRecordingSettings() }
                } else {
                    Text("Microphone permission is needed").font(.title3.bold())
                    Text("Open System Settings › Privacy & Security › Microphone and turn on MeetingScribe, then press Start again.")
                    Button("Open Microphone settings") { AppModel.openMicrophoneSettings() }
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color(red: 0.55, green: 0.30, blue: 0.0))
    }
}

@available(macOS 26.0, *)
struct TranscriptPane: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TRANSCRIPT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                legend("REMOTE", Palette.remote)
                legend("LOCAL", Palette.local)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(m.utterances) { u in UtteranceRow(u: u) }
                        ForEach([Channel.remote, .local], id: \.self) { ch in
                            if let v = m.volatile[ch], !v.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("  …   ").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    ChannelTag(ch: ch).opacity(0.6)
                                    Text(v).italic().foregroundStyle(.secondary)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onChange(of: m.utterances.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: m.volatile) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    func legend(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(s).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct ChannelTag: View {
    let ch: Channel
    var body: some View {
        Text(ch == .remote ? "REMOTE" : "LOCAL")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(ch == .remote ? Palette.remote : Palette.local)
            .frame(width: 52, alignment: .leading)
    }
}

struct UtteranceRow: View {
    let u: Utterance
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Fmt.clock.string(from: u.t)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            ChannelTag(ch: u.ch)
            Text(u.text).font(.body)
                .foregroundStyle(u.ch == .local ? Palette.local : .primary)
        }
    }
}

@available(macOS 26.0, *)
struct SuggestionsPane: View {
    @EnvironmentObject var m: AppModel
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SUGGESTIONS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("newest first").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if m.suggestions.isEmpty {
                VStack {
                    Spacer()
                    Text(m.isRecording ? "Listening. Silence is normal." : "Press Start when the meeting begins.")
                        .font(.system(size: fontSize * 0.8, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(m.suggestions) { s in
                            SuggestionCard(s: s, fontSize: fontSize, isLatest: m.latestBatch.contains(s.id))
                        }
                    }
                    .padding(16)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

struct SuggestionCard: View {
    let s: Suggestion
    let fontSize: Double
    let isLatest: Bool

    var body: some View {
        let c = Palette.tag(s.kind)
        let isFlag = s.kind == .flag
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.kind.rawValue)
                    .font(.system(size: max(14, fontSize * 0.55), weight: .black))
                    .foregroundStyle(isFlag ? c : .white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isFlag ? Color.white : c))
                Text(Fmt.clock.string(from: s.at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isFlag ? .white.opacity(0.85) : .secondary)
            }
            .frame(width: max(90, fontSize * 3.4), alignment: .leading)
            Text(s.text)
                .font(.system(size: isFlag ? fontSize * 1.05 : fontSize, weight: isFlag ? .bold : .semibold))
                .foregroundStyle(isFlag ? .white : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(isFlag ? c : c.opacity(0.14)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFlag ? Color.white.opacity(0.9) : c.opacity(0.6), lineWidth: isFlag ? 3 : 1.5)
        )
        .opacity(isLatest ? 1 : 0.6)
    }
}
