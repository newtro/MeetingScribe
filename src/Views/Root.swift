import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct RootView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let b = m.blocker { PermissionBanner(blocker: b) }
                if let e = m.errorText { ErrorBanner(text: e) { m.errorText = nil } }
                detail
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !m.isRecording { m.reloadBriefs() }
            m.reloadSessions()
        }
        .navigationTitle(m.isRecording ? "● Recording — \(m.meeting.title)" : "MeetingScribe")
    }

    @ViewBuilder private var detail: some View {
        switch m.route {
        case .prep: PrepView()
        case .live: LiveView()
        case .brief(let url): BriefView(url: url).id(url)
        case .session(let dir): SessionView(dir: dir).id(dir)
        }
    }
}

@available(macOS 26.0, *)
struct Sidebar: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        List(selection: Binding<AppModel.Route?>(get: { m.route }, set: { if let r = $0 { m.route = r } })) {
            if m.phase != .idle {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recording").font(.headline)
                        Text(m.meeting.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "record.circle.fill").foregroundStyle(Palette.rec)
                }
                .tag(AppModel.Route.live)
            }
            Label("New Meeting", systemImage: "plus.circle.fill")
                .tag(AppModel.Route.prep)

            Section("Briefs") {
                if m.briefs.isEmpty {
                    Text("None yet").foregroundStyle(.tertiary)
                }
                ForEach(m.briefs, id: \.self) { url in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Paths.briefName(url)).lineLimit(1)
                            if let d = modified(url) {
                                Text(d.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: url == m.brief ? "doc.text.fill" : "doc.text")
                    }
                    .tag(AppModel.Route.brief(url))
                    .contextMenu {
                        Button("Start Meeting with This Brief") { m.startMeeting(with: url) }.disabled(m.phase != .idle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }

            Section("Meetings") {
                if m.sessions.isEmpty {
                    Text("No recordings yet").foregroundStyle(.tertiary)
                }
                ForEach(m.sessions) { s in
                    SessionRow(s: s, summarizing: m.summarizing.contains(s.dir))
                        .tag(AppModel.Route.session(s.dir))
                        .contextMenu {
                            Button("Export Markdown…") { m.export(s.dir) }
                            Button("Copy Transcript") { m.copyTranscript(s.dir) }
                            Button("Show in Finder") { NSWorkspace.shared.open(s.dir) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

struct SessionRow: View {
    let s: SessionInfo
    let summarizing: Bool
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(s.start.formatted(date: .abbreviated, time: .shortened))
                    if let d = s.duration, d > 0 { Text("· \(Fmt.duration(d))") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        } icon: {
            if summarizing { ProgressView().controlSize(.mini) }
            else { Image(systemName: s.hasSummary ? "text.document.fill" : "waveform") }
        }
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.callout).lineLimit(3)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.9))
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
                    Text("MeetingScribe captures call audio through ScreenCaptureKit. Open System Settings › Privacy & Security › Screen & System Audio Recording, turn on MeetingScribe, then quit and reopen MeetingScribe.")
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

struct SettingsView: View {
    @AppStorage(Prefs.userName) private var userName = ""
    @AppStorage(Prefs.claudePath) private var claudePath = ""
    @AppStorage(Prefs.advisorInterval) private var interval: Double = 45
    @AppStorage(Prefs.autoSummary) private var autoSummary = true
    @AppStorage(Prefs.briefModel) private var briefModel = ""

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $userName, prompt: Text(Prefs.user))
                Text("Used in briefs, the advisor prompt (“\(Prefs.user)'s microphone”) and summaries.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live advisor") {
                Picker("Check every", selection: $interval) {
                    Text("30 seconds").tag(30.0)
                    Text("45 seconds").tag(45.0)
                    Text("1 minute").tag(60.0)
                    Text("90 seconds").tag(90.0)
                    Text("2 minutes").tag(120.0)
                }
            }
            Section("After the meeting") {
                Toggle("Write a summary automatically when recording stops", isOn: $autoSummary)
            }
            Section("Claude") {
                TextField("claude CLI", text: $claudePath, prompt: Text(ClaudeCLI.path))
                TextField("Model for briefs", text: $briefModel, prompt: Text("default"))
                Text("Leave blank for defaults. Briefs, the advisor and summaries all run through the claude CLI; only text and the files Claude chooses to read for a brief are sent — never audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
