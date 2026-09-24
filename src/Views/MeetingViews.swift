import AppKit
import SwiftUI

// MARK: - Live

@available(macOS 26.0, *)
struct LiveView: View {
    @EnvironmentObject var m: AppModel
    @AppStorage("suggestionFontSize") var fontSize: Double = 26
    @AppStorage("liveTab") var tab = "suggestions"

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(fontSize: $fontSize)
            HSplitView {
                TranscriptList(utterances: m.utterances, names: m.speakerNames, highlights: m.highlights,
                               volatile: m.volatile, follow: true,
                               onRename: { spk, name in if let d = m.sessionDir { m.rename(spk, to: name, in: d) } })
                    .frame(minWidth: 340, idealWidth: 480)
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("Suggestions\(m.suggestions.isEmpty ? "" : " (\(m.suggestions.count))")").tag("suggestions")
                        Text("Notes\(m.highlights.isEmpty ? "" : " · \(m.highlights.count) marked")").tag("notes")
                        Text("Brief").tag("brief")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(10)
                    Divider()
                    switch tab {
                    case "notes": NotesPane(notes: $m.notes, highlights: m.highlights) { h, note in m.updateHighlight(h, note: note) }
                    case "brief": BriefPreview(url: m.hasBrief ? m.brief : nil)
                    default: SuggestionsPane(fontSize: fontSize)
                    }
                }
                .frame(minWidth: 480, idealWidth: 860)
            }
        }
    }
}

@available(macOS 26.0, *)
struct ControlBar: View {
    @EnvironmentObject var m: AppModel
    @Binding var fontSize: Double

    var body: some View {
        HStack(spacing: 14) {
            Button(action: m.toggle) {
                Label(m.isRecording ? "Stop" : (m.phase == .starting ? "Starting…" : "Stopping…"),
                      systemImage: m.isRecording ? "stop.fill" : "hourglass")
                    .font(.headline)
                    .frame(minWidth: 84)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.black.opacity(0.5))
            .disabled(!m.isRecording)

            RecordingBadge()
            if let s = m.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsedString(from: s, to: ctx.date))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(m.meeting.title).font(.headline).lineLimit(1)
                    .layoutPriority(-1)
                Text(m.hasBrief ? "Brief: \(Paths.briefName(m.brief))" : "No brief — transcript only")
                    .font(.caption).opacity(0.85).lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if m.advisorBusy { ProgressView().controlSize(.small).tint(.white) }
                Text(m.advisorStatus).font(.callout).lineLimit(1).opacity(0.9)
            }
            .layoutPriority(-2)
            Button { Task { await m.askNow() } } label: {
                Label("Ask now", systemImage: "sparkles").font(.headline)
            }
            .controlSize(.large)
            .disabled(!m.isRecording || m.advisorBusy || !m.hasBrief)
            .help("Run the advisor now (⌘↩)")
            Button { m.markMoment() } label: {
                Label("Mark", systemImage: "bookmark.fill").font(.headline)
            }
            .controlSize(.large)
            .disabled(!m.isRecording)
            .help("Mark this moment (⌘B) — add a note in the Notes tab")

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
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.rec)
    }
}

/// Stays visible on screen shares so everyone can see the meeting is being transcribed.
struct RecordingBadge: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 11, height: 11)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("RECORDING · this meeting is being transcribed")
                .font(.system(size: 14, weight: .heavy))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .onAppear { pulse = true }
    }
}

@available(macOS 26.0, *)
struct SuggestionsPane: View {
    @EnvironmentObject var m: AppModel
    let fontSize: Double

    var body: some View {
        if m.suggestions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: m.hasBrief ? "ear" : "doc.badge.ellipsis").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(m.hasBrief ? "Listening. Silence is normal." : "No brief for this meeting, so no live advice.\nThe transcript and summary still work.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: fontSize * 0.7, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Free-form notes plus the moments marked during the meeting (each can carry a note).
struct NotesPane: View {
    @Binding var notes: String
    let highlights: [Highlight]
    let onNote: (Highlight, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                if notes.isEmpty {
                    Text("Your notes. Saved with the session and used for the summary.")
                        .foregroundStyle(.tertiary).padding(.horizontal, 17).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            if !highlights.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Marked moments", systemImage: "bookmark")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(highlights) { h in MomentEditor(h: h, onNote: onNote) }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding(12)
            }
        }
    }
}

struct MomentEditor: View {
    let h: Highlight
    let onNote: (Highlight, String) -> Void
    @State private var text = ""
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill").foregroundStyle(Palette.highlight)
            Text(Fmt.clock.string(from: h.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            TextField("What happened here?", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onNote(h, text) }
                .onAppear { text = h.note }
        }
    }
}

struct BriefPreview: View {
    let url: URL?
    var body: some View {
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView { MarkdownView(text: text, baseSize: 14).padding(20) }
        } else {
            Text("No brief for this meeting.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Review a past meeting

@available(macOS 26.0, *)
struct SessionView: View {
    @EnvironmentObject var m: AppModel
    let dir: URL
    @AppStorage("sessionTab") var tab = "summary"
    @State private var utterances: [Utterance] = []
    @State private var names: [String: String] = [:]
    @State private var highlights: [Highlight] = []
    @State private var notes = ""
    @State private var summary: String?
    @State private var suggestions: [Suggestion] = []
    @State private var info: MeetingInfo?
    @State private var title = ""
    @State private var loaded = false

    private var files: SessionFiles { SessionFiles(dir: dir) }
    private var start: Date { Fmt.iso.date(from: dir.lastPathComponent) ?? Date() }
    private var isLive: Bool { m.isRecording && m.sessionDir == dir }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                TranscriptList(utterances: utterances, names: names, highlights: highlights,
                               onRename: { spk, name in m.rename(spk, to: name, in: dir) })
                    .frame(minWidth: 360, idealWidth: 540)
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("Summary").tag("summary")
                        Text("Suggestions\(suggestions.isEmpty ? "" : " (\(suggestions.count))")").tag("suggestions")
                        Text("Notes").tag("notes")
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(10)
                    Divider()
                    switch tab {
                    case "suggestions": suggestionsTab
                    case "notes":
                        NotesPane(notes: $notes, highlights: highlights) { h, note in
                            if let i = highlights.firstIndex(of: h) {
                                highlights[i].note = note
                                files.rewrite(highlights: highlights)
                            }
                        }
                        .onChange(of: notes) { if loaded { files.save(notes: notes) } }
                    default: summaryTab
                    }
                }
                .frame(minWidth: 420, idealWidth: 700)
            }
        }
        .onAppear(perform: load)
        .onChange(of: m.sessionRevision) { load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { m.renameSession(dir, title: title) }
                HStack(spacing: 10) {
                    Label(start.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                    if let d = duration { Label(Fmt.duration(d), systemImage: "clock") }
                    Label("\(Set(utterances.compactMap(\.spk)).count) speakers", systemImage: "person.2")
                    if let b = info?.brief { Label(Paths.briefName(URL(fileURLWithPath: b)), systemImage: "doc.text") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { m.copyTranscript(dir) } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
            Button { m.export(dir) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            Button { NSWorkspace.shared.open(dir) } label: { Image(systemName: "folder") }.help("Show session folder")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder private var summaryTab: some View {
        if m.summarizing.contains(dir) {
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is writing the summary, decisions and action items…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                        }
                        Button("Regenerate", systemImage: "arrow.clockwise") { m.summarize(dir) }.disabled(isLive)
                    }
                    .controlSize(.small)
                    MarkdownView(text: summary, baseSize: 15)
                }
                .padding(24)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "text.document").font(.system(size: 40)).foregroundStyle(.tertiary)
                if let err = m.summaryErrors[dir] {
                    Text(err).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled)
                }
                Text("Summary, decisions, action items and a follow-up email draft.").foregroundStyle(.secondary)
                Button { m.summarize(dir) } label: { Label("Write summary", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(utterances.isEmpty || isLive)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var suggestionsTab: some View {
        if suggestions.isEmpty {
            Text("The advisor had nothing to say in this meeting.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(suggestions) { s in SuggestionCard(s: s, fontSize: 17, isLatest: true) }
                }
                .padding(16)
                .textSelection(.enabled)
            }
        }
    }

    private var duration: TimeInterval? {
        (info?.ended ?? utterances.map(\.t).max()).map { $0.timeIntervalSince(start) }
    }

    private func load() {
        loaded = false
        let f = files
        utterances = f.utterances.sorted { $0.t < $1.t }
        names = f.speakers
        highlights = f.highlights
        notes = f.notes
        summary = f.summary
        suggestions = Suggestion.parse(markdown: f.suggestionsMarkdown, day: start)
        info = f.meeting
        title = info?.title ?? SessionInfo.load(dir)?.title ?? "Meeting"
        DispatchQueue.main.async { loaded = true }
    }
}
