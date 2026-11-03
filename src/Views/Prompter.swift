import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct PrompterPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var following = true
    @State private var unseen = 0
    @State private var expanded = Set<UUID>()
    @State private var dashboard = false
    @State private var question = ""
    @State private var selectedTopic: UUID?
    @AppStorage("prompterTextSize") private var textSize = 20.0
    @AppStorage("prompterOnTop") private var onTop = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(m.isRecording ? Color.red : .secondary).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.meeting.title.isEmpty ? "Meeting prompter" : m.meeting.title).font(.headline).lineLimit(1)
                    Text(m.isRecording ? m.live.status : "Start a project meeting to listen").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { dashboard.toggle() } label: { Image(systemName: dashboard ? "rectangle.compress.vertical" : "rectangle.expand.vertical") }
                    .help(dashboard ? "Collapse dashboard" : "Expand dashboard")
                Menu {
                    Toggle("Keep on top", isOn: $onTop)
                    Button("Larger text") { textSize = min(28, textSize + 2) }
                    Button("Smaller text") { textSize = max(16, textSize - 2) }
                    Button("Open separate prompter") { openWindow(id: "prompter") }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 25)
                Button(m.isRecording ? "Stop" : "Start") { if m.isRecording { m.toggle() } else { m.startMeeting() } }
                    .disabled(m.phase == .starting || m.phase == .stopping || (!m.isRecording && !m.modelReady))
            }.padding(16)
            if let error = m.persistenceError { Text(error).font(.callout.bold()).foregroundStyle(.red).padding(.horizontal, 16) }
            if m.selectedProjectID != nil {
                TopicCloudView(topics: m.live.topics, selectedID: $selectedTopic).padding(.horizontal, 16).padding(.bottom, 12)
                if let id = selectedTopic, let topic = m.live.topics.first(where: { $0.id == id }) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topic.title).font(.headline)
                            Text(topic.status).font(.caption).foregroundStyle(.secondary)
                            if let cueID = topic.cueID, let cue = m.live.cues.first(where: { $0.id == cueID }) { Text(cue.text).font(.callout) }
                        }
                        Spacer()
                        Button { m.live.pin(topicID: topic.id) } label: { Image(systemName: topic.pinned ? "pin.fill" : "pin") }.help(topic.pinned ? "Unpin topic" : "Pin topic")
                        Button { selectedTopic = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(.quaternary.opacity(0.4)).padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            Divider()
            if m.selectedProjectID == nil {
                SuggestionsPane(fontSize: textSize)
            } else if visibleCues.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "ear.badge.waveform").font(.system(size: 36)).foregroundStyle(.teal)
                    Text(m.isRecording ? "Listening. Silence is normal." : "Your next useful thought, at a glance.").font(.title3.weight(.medium))
                    Text("Answers, questions and proposals appear here when they matter.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                AnchoredPrompterFeed(items: visibleCues.map { cue in
                    PrompterFeedItem(id: cue.id, view: AnyView(cueView(cue)))
                }, following: $following)
            }
            if !following {
                Button { following = true; unseen = 0 } label: {
                    Label(unseen > 0 ? "\(unseen) new · Jump to latest" : "Reviewing · Jump to latest", systemImage: "arrow.down")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).padding(10)
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Ask about this discussion…", text: $question).textFieldStyle(.roundedBorder)
                    .onSubmit(submitQuestion).disabled(!m.isRecording)
                Button(action: submitQuestion) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(!m.isRecording || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if m.selectedProjectID != nil {
                    Toggle("Fast", isOn: Binding(get: { m.live.fastMode }, set: { m.live.fastMode = $0 })).toggleStyle(.switch).controlSize(.small)
                        .help("Request premium Claude Opus Fast mode for technical research. Uses additional paid usage; does not change transcription or detection.")
                }
            }.padding(12)
            if m.live.fastMode { Text("Opus Fast requested · premium usage · effective speed may vary").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8) }
            if dashboard {
                Divider()
                TabView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if m.live.backgroundCues.isEmpty { Text("No background results yet.").foregroundStyle(.secondary) }
                            ForEach(m.live.backgroundCues.filter { $0.status != "dismissed" }) { cue in
                                VStack(alignment: .leading) {
                                    cueView(cue)
                                    if cue.status == "background" { Button("Show in prompter") { m.live.showBackground(cueID: cue.id) }.padding(.horizontal, 18) }
                                }
                            }
                            ForEach(m.live.issues) { issue in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(issue.title).font(.headline)
                                    Text(issue.question).font(.callout)
                                    Text(issue.state).font(.caption).foregroundStyle(.secondary)
                                }.padding(.horizontal, 18)
                            }
                            if let receipt = m.live.lastReceipt { Text(receipt.description).font(.caption.monospaced()).foregroundStyle(.secondary).padding(18) }
                        }.padding(.vertical, 10)
                    }.tabItem { Label("Research", systemImage: "magnifyingglass") }
                    TranscriptList(utterances: m.utterances, names: m.speakerNames, highlights: m.highlights,
                                   volatile: m.volatile, follow: true,
                                   onRename: { spk, name in if let dir = m.sessionDir { m.rename(spk, to: name, in: dir) } })
                        .tabItem { Label("Transcript", systemImage: "waveform") }
                    NotesPane(notes: $m.notes, highlights: m.highlights) { h, note in m.updateHighlight(h, note: note) }
                        .tabItem { Label("Notes", systemImage: "note.text") }
                    BriefPreview(url: m.meeting.brief.map { URL(fileURLWithPath: $0) })
                        .tabItem { Label("Brief", systemImage: "doc.text") }
                }.frame(minHeight: 200, idealHeight: 280, maxHeight: 360)
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowLevelReader(onTop: onTop))
        .onChange(of: m.live.cues.count) { old, new in if !following { unseen += max(0, new - old) } }
        .onChange(of: following) { _, value in if value { unseen = 0 } }
    }

    private var visibleCues: [LiveCue] { m.live.cues.filter { $0.status != "dismissed" } }

    private func submitQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard m.isRecording, !text.isEmpty else { return }
        if m.selectedProjectID != nil { m.live.ask(text) } else { Task { await m.askNow() } }
        question = ""
    }

    private func cueView(_ cue: LiveCue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(cue.label).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(cue.label == "PROPOSAL" ? Color.purple : (cue.label == "REPORTED" ? .orange : .teal))
                Text(cue.kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(cue.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                Button { m.live.dismiss(cueID: cue.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss cue")
            }
            Text(cue.text).font(.system(size: textSize, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !cue.status.isEmpty { Text(cue.status).font(.caption).foregroundStyle(.secondary) }
            if cue.claimKind == .proposal {
                if !cue.assumptions.isEmpty { Text("Assumes: " + cue.assumptions.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary) }
                if let validation = cue.validation { Text("Check: " + validation).font(.caption).foregroundStyle(.secondary) }
                Menu("Status: " + (cue.proposalStatus ?? "proposed")) {
                    ForEach(["proposed", "discussed", "investigate", "acceptedForImplementation", "rejected", "superseded"], id: \.self) { status in
                        Button(status.capitalized) { m.live.setProposalStatus(cueID: cue.id, status: status) }
                    }
                }.font(.caption).menuStyle(.borderlessButton).fixedSize()
            }
            if !cue.sourceIDs.isEmpty {
                Button(expanded.contains(cue.id) ? "Hide evidence" : "Evidence · \(cue.sourceIDs.count)") {
                    if expanded.contains(cue.id) { expanded.remove(cue.id) } else { expanded.insert(cue.id) }
                }.buttonStyle(.link).font(.caption)
                if expanded.contains(cue.id) { Text(cue.evidence).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 14).padding(.vertical, 6)
    }
}

struct PrompterFeedItem { let id: UUID; let view: AnyView }

/// Keeps a concrete card and its pixel offset anchored; only user input can end following.
struct AnchoredPrompterFeed: NSViewRepresentable {
    let items: [PrompterFeedItem]
    @Binding var following: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FeedScrollView {
        let scroll = FeedScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = FlippedFeedDocument()
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        scroll.userInput = { [weak coordinator = context.coordinator] down in coordinator?.userInput(down: down) }
        scroll.afterInput = { [weak coordinator = context.coordinator] in coordinator?.settle() }
        scroll.didLayout = { [weak coordinator = context.coordinator] in coordinator?.resizeIfNeeded() }
        let scroller = FeedScroller()
        scroller.willTrack = { [weak coordinator = context.coordinator] in coordinator?.userInput(down: false) }
        scroller.didTrack = { [weak coordinator = context.coordinator] in coordinator?.userInput(down: true); coordinator?.settle() }
        scroll.verticalScroller = scroller
        return scroll
    }
    func updateNSView(_ scroll: FeedScrollView, context: Context) {
        context.coordinator.following = $following
        context.coordinator.items = items
        context.coordinator.layout()
    }
    static func dismantleNSView(_ nsView: FeedScrollView, coordinator: Coordinator) { coordinator.cleanup() }

    final class Coordinator {
        weak var scroll: FeedScrollView?
        var items: [PrompterFeedItem] = []
        var hosts: [UUID: NSHostingView<AnyView>] = [:]
        var following: Binding<Bool> = .constant(true)
        var observer: NSObjectProtocol?
        var width: CGFloat = 0
        var layingOut = false
        var manualDown = false
        var inputRevision = 0
        func cleanup() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
        deinit { cleanup() }
        func userInput(down: Bool) { inputRevision += 1; manualDown = down; following.wrappedValue = false }
        func settle() {
            guard !layingOut, manualDown else { return }
            let revision = inputRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, revision == self.inputRevision, self.manualDown, let scroll = self.scroll, let doc = scroll.documentView else { return }
                self.manualDown = false
                if doc.bounds.height - scroll.contentView.bounds.maxY <= 4 { self.following.wrappedValue = true }
            }
        }
        func resizeIfNeeded() {
            guard let scroll, abs(width - scroll.contentView.bounds.width) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in self?.layout() }
        }
        func layout() {
            guard !layingOut, let scroll, let doc = scroll.documentView else { return }
            layingOut = true
            defer { layingOut = false }
            let oldY = scroll.contentView.bounds.minY
            let anchor = hosts.first { $0.value.frame.minY <= oldY && $0.value.frame.maxY > oldY }.map { ($0.key, oldY - $0.value.frame.minY) }
            width = max(280, scroll.contentView.bounds.width)
            let ids = Set(items.map(\.id))
            for id in Array(hosts.keys) where !ids.contains(id) { hosts.removeValue(forKey: id)?.removeFromSuperview() }
            var y: CGFloat = 8
            for item in items {
                let view = AnyView(item.view.frame(width: width).fixedSize(horizontal: false, vertical: true))
                let host = hosts[item.id] ?? NSHostingView(rootView: view)
                host.rootView = view
                if host.superview == nil { doc.addSubview(host); hosts[item.id] = host }
                host.frame.size.width = width
                host.layoutSubtreeIfNeeded()
                let height = max(40, host.fittingSize.height)
                host.frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height
            }
            doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentView.bounds.height))
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            let target: CGFloat
            if following.wrappedValue { target = maxY }
            else if let anchor, let host = hosts[anchor.0] { target = min(maxY, max(0, host.frame.minY + anchor.1)) }
            else { target = min(maxY, oldY) }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

final class FlippedFeedDocument: NSView { override var isFlipped: Bool { true } }
final class FeedScrollView: NSScrollView {
    var userInput: ((Bool) -> Void)?
    var afterInput: (() -> Void)?
    var didLayout: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        userInput?(event.scrollingDeltaY < 0)
        super.scrollWheel(with: event)
        afterInput?()
    }
    override func keyDown(with event: NSEvent) {
        userInput?([UInt16(125), 121, 119].contains(event.keyCode))
        super.keyDown(with: event); afterInput?()
    }
    override func layout() { super.layout(); didLayout?() }
}
final class FeedScroller: NSScroller {
    var willTrack: (() -> Void)?; var didTrack: (() -> Void)?
    override func mouseDown(with event: NSEvent) { willTrack?(); super.mouseDown(with: event); didTrack?() }
}
struct WindowLevelReader: NSViewRepresentable {
    let onTop: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = onTop ? .floating : .normal }
    }
}
