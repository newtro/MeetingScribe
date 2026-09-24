import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// New Meeting: describe it, point Claude at material, get a brief — or just start recording.
@available(macOS 26.0, *)
struct PrepView: View {
    @EnvironmentObject var m: AppModel
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New meeting").font(.system(size: 30, weight: .bold))
                    Text("Tell Claude what the meeting is about and where the background lives. It reads the material and writes the brief the live advisor works from. Or skip straight to recording.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let job = m.job, job.target == nil {
                    BuildProgress(job: job, title: "Writing the brief")
                } else {
                    form
                }
            }
            .padding(32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var form: some View {
        Card {
            SectionHeader(title: "About the meeting", systemImage: "person.2")
            TextField("Title", text: $m.draft.title, prompt: Text("e.g. Park Lawn discovery call"))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $m.draft.description)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                if m.draft.description.isEmpty {
                    Text("What's it about? Who's in it, what's at stake, what you need to walk away with, what you're worried about…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            TextField("Attendees", text: $m.draft.attendees, prompt: Text("Attendees (optional) — names, roles, companies"))
                .textFieldStyle(.roundedBorder)
        }

        Card {
            HStack {
                SectionHeader(title: "Material for Claude to read", systemImage: "folder")
                Spacer()
                Button("Add Folder…", systemImage: "plus", action: addFolder)
            }
            if m.draft.materials.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title)
                    Text("Drop folders here — project repos, client folders, contracts, notes")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            } else {
                VStack(spacing: 6) {
                    ForEach(m.draft.materials, id: \.self) { p in
                        HStack {
                            Image(systemName: isRepo(p) ? "chevron.left.forwardslash.chevron.right" : "folder.fill")
                                .foregroundStyle(Color.accentColor).frame(width: 20)
                            Text(URL(fileURLWithPath: p).abbreviatedPath).lineLimit(1).truncationMode(.middle)
                            if isRepo(p) { Text("git").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                            Spacer()
                            Button { m.draft.materials.removeAll { $0 == p } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
            }
            Toggle("Also let Claude search the web for public background on the people and companies", isOn: $m.draft.allowWeb)
            Text("Claude starts from these folders and can read anything else on this Mac it needs; it cannot change files. What it reads is sent to Claude to write the brief. Audio never leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)

        if let err = m.job?.error {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }

        HStack(spacing: 12) {
            Button(action: { m.buildBrief() }) {
                Label("Build brief with Claude", systemImage: "sparkles")
                    .font(.headline).padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(m.draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && m.draft.materials.isEmpty)

            Spacer()

            if !m.briefs.isEmpty {
                Picker("Brief", selection: Binding(get: { m.brief }, set: { m.brief = $0 })) {
                    ForEach(m.briefs, id: \.self) { u in Text(Paths.briefName(u)).tag(u) }
                }
                .frame(maxWidth: 260)
            }
            Button(action: { m.startMeeting() }) {
                Label("Start recording", systemImage: "record.circle")
                    .font(.headline).padding(.horizontal, 6).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Palette.rec)
            .disabled(m.phase != .idle)
            .help(m.hasBrief ? "Record now, advised by the selected brief" : "Record without a brief (no live advisor)")
        }
        Text(m.modelStatus).font(.caption).foregroundStyle(.tertiary)
    }

    private func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add([url]) }
            }
        }
        return true
    }

    private func add(_ urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            let folder = isDir.boolValue ? u : u.deletingLastPathComponent()
            if !m.draft.materials.contains(folder.path) { m.draft.materials.append(folder.path) }
        }
    }
}

/// Live feed of what Claude is doing while it writes or revises a brief.
@available(macOS 26.0, *)
struct BuildProgress: View {
    @EnvironmentObject var m: AppModel
    let job: AppModel.BuildJob
    let title: String

    var body: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("\(elapsedString(from: job.started, to: ctx.date)) · \(job.steps.filter { !$0.hasPrefix("·") }.count) steps · usually 1–4 minutes")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { m.cancelBuild() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(job.steps.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: s.hasPrefix("·") ? "text.bubble" : icon(s))
                                    .foregroundStyle(.secondary).frame(width: 16)
                                Text(s.hasPrefix("· ") ? String(s.dropFirst(2)) : s)
                                    .font(s.hasPrefix("·") ? .callout.italic() : .callout)
                                    .foregroundStyle(i == job.steps.count - 1 ? .primary : .secondary)
                                    .lineLimit(2)
                            }
                            .id(i)
                        }
                        if job.steps.isEmpty {
                            Text("Starting Claude…").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 280)
                .onChange(of: job.steps.count) { proxy.scrollTo(job.steps.count - 1, anchor: .bottom) }
            }
        }
    }

    private func icon(_ s: String) -> String {
        if s.hasPrefix("Reading") { return "doc.text" }
        if s.hasPrefix("Searching the web") { return "globe" }
        if s.hasPrefix("Searching") { return "magnifyingglass" }
        if s.hasPrefix("Listing") { return "folder" }
        if s.hasPrefix("Running") { return "terminal" }
        return "circle"
    }
}

/// A brief: read it, edit it, have Claude revise it, start a meeting with it.
@available(macOS 26.0, *)
struct BriefView: View {
    @EnvironmentObject var m: AppModel
    let url: URL
    @State private var text = ""
    @State private var saved = ""
    @State private var editing = false
    @State private var instruction = ""

    private var dirty: Bool { text != saved }
    private var refiningThis: Bool { m.job?.target == url }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if refiningThis, let job = m.job, job.running {
                ScrollView { BuildProgress(job: job, title: "Claude is revising this brief").padding(24) }
            } else if editing {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(16)
            } else {
                ScrollView {
                    MarkdownView(text: text, baseSize: 15)
                        .padding(.horizontal, 36).padding(.vertical, 24)
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            refineBar
        }
        .onAppear(perform: load)
        .onChange(of: m.sessionRevision) { if !dirty { load() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Paths.briefName(url)).font(.title2.bold()).lineLimit(1)
                HStack(spacing: 6) {
                    if let meta = m.meta(forBrief: url), !meta.materials.isEmpty {
                        Label(meta.materials.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), systemImage: "folder")
                    }
                    Text("\(text.split(whereSeparator: \.isWhitespace).count) words")
                    if dirty { Text("· edited").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $editing) {
                Text("Read").tag(false)
                Text("Edit").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            if dirty {
                Button("Revert") { text = saved }
                Button("Save") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open in Default Editor") { NSWorkspace.shared.open(url) }
                if FileManager.default.fileExists(atPath: prevURL.path) {
                    Button("Restore Version Before Last Revision") { restorePrevious() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 32)
            Button {
                if dirty { save() }
                m.startMeeting(with: url)
            } label: {
                Label("Start meeting", systemImage: "record.circle").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.rec)
            .controlSize(.large)
            .disabled(m.phase != .idle)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var refineBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if refiningThis, let err = m.job?.error {
                HStack {
                    Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { m.cancelBuild() }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                TextField("Ask Claude to change this brief — “add the pricing from the renewal PDF”, “Tim won't attend”…",
                          text: $instruction)
                    .textFieldStyle(.plain)
                    .onSubmit(refine)
                    .disabled(m.job?.running == true)
                Button("Revise", action: refine)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || m.job?.running == true || dirty)
                    .help(dirty ? "Save your edits first" : "Claude rewrites the brief, re-reading material as needed")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
        .padding(14)
    }

    private var prevURL: URL {
        Paths.briefMeta.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".prev.md")
    }

    private func load() {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        saved = text
    }

    private func save() {
        try? text.write(to: url, atomically: true, encoding: .utf8)
        saved = text
        m.reloadBriefs()
    }

    private func refine() {
        let i = instruction.trimmingCharacters(in: .whitespaces)
        guard !i.isEmpty, !dirty else { return }
        m.refine(url, instruction: i)
        instruction = ""
        editing = false
    }

    private func restorePrevious() {
        guard let prev = try? String(contentsOf: prevURL, encoding: .utf8) else { return }
        text = prev
        save()
    }
}
