import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct ProjectsView: View {
    @EnvironmentObject var m: AppModel
    @State private var creating = false
    @State private var renaming: ProjectProfile?
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Walk in ready.").font(.system(size: 34, weight: .semibold))
                        Text("Open a project. Your notes, AI history and Git changes become your meeting brief.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("New project", systemImage: "plus") { creating = true }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.phase != .idle)
                }
                if m.projects.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 50)).foregroundStyle(.secondary)
                        Text("A name and a folder. That's all.").font(.title2.weight(.medium))
                        Text("Choose your project repository or a folder containing several repositories. Preparation starts automatically.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 450)
                        Button("Choose your first project") { creating = true }.controlSize(.large)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 16) {
                        ForEach(m.projects, id: \.id) { project in
                            VStack(alignment: .leading, spacing: 16) {
                                Image(systemName: "folder.fill").font(.title).foregroundStyle(.teal)
                                Text(project.name).font(.title2.weight(.semibold)).lineLimit(2)
                                Text(project.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                HStack {
                                    Button("Open & prepare", systemImage: "arrow.up.right") { m.openProject(project.id) }
                                        .buttonStyle(.borderedProminent)
                                    Spacer()
                                    Menu {
                                        Button("Rename") { name = project.name; renaming = project }
                                        Button("Locate folder…") { m.relocateProject(project) }
                                        Button("Forget project") { m.archiveProject(project) }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                                }.disabled(m.phase != .idle)
                            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                }
                Button("Advanced: prepare a meeting manually") { m.selectedProjectID = nil; m.preparation.cancel(); m.route = .prep }
                    .buttonStyle(.link).disabled(m.phase != .idle)
            }.padding(32).frame(maxWidth: 1100, alignment: .leading)
        }
        .sheet(isPresented: $creating) { CreateProjectSheet() }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename project").font(.title2)
                TextField("Project name", text: $name)
                HStack { Button("Cancel") { renaming = nil }; Spacer(); Button("Save") {
                    if let project = renaming { m.renameProject(project, to: name) }; renaming = nil
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 400)
        }
    }
}

@available(macOS 26.0, *)
struct CreateProjectSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New project").font(.title.bold())
            Text("Preparation begins as soon as you add the folder.").foregroundStyle(.secondary)
            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    folder = url
                    if name.isEmpty { name = url.lastPathComponent }
                }
            } label: { Label(folder?.path ?? "Choose project folder…", systemImage: "folder") }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create & prepare") {
                    if let folder { m.createProject(name: name, root: folder); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 520)
    }
}

@available(macOS 26.0, *)
struct ProjectPreparationView: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var prep: ProjectPreparation
    let project: ProjectProfile
    @State private var sourcesExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name).font(.largeTitle.bold())
                        Text(project.rootPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { m.refreshProject() }.disabled(prep.isPreparing)
                    Button("Start meeting", systemImage: "record.circle") { m.startProjectMeeting() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!m.modelReady || m.phase != .idle)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if prep.isPreparing { ProgressView().controlSize(.small) }
                        Image(systemName: prep.isPreparing ? "doc.text.magnifyingglass" : (prep.error == nil && prep.packet != nil ? "checkmark.circle.fill" : "exclamationmark.circle"))
                            .foregroundStyle(prep.error == nil ? Color.teal : .orange)
                        Text(prep.status).font(.headline)
                        Spacer()
                        if prep.isPreparing { Button("Cancel") { prep.cancel() } }
                    }
                    Label(m.modelStatus, systemImage: m.modelReady ? "waveform" : "hourglass").font(.callout)
                    Label(m.diarizationStatus, systemImage: m.diarizationReady ? "person.wave.2" : "person.crop.circle.badge.exclamationmark")
                        .font(.callout).foregroundStyle(m.diarizationReady ? Color.secondary : .orange)
                    Label(m.capturePermissions.microphoneLabel, systemImage: "mic").font(.callout)
                    Label(m.capturePermissions.screenAudioLabel, systemImage: "speaker.wave.2").font(.callout)
                    if let error = prep.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if prep.isPreparing { Text("You can start recording while context is preparing. Live advice gains the new brief when it is ready.").font(.caption).foregroundStyle(.secondary) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                if let packet = prep.packet {
                    HStack {
                        Text(prep.isPreparing || prep.error != nil ? "Previous snapshot" : "Your brief").font(.title2.bold())
                        Spacer()
                        Text(packet.preparedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownView(text: packet.briefMarkdown, baseSize: 16)
                }
                if let manifest = prep.manifest {
                    DisclosureGroup("Sources · \(manifest.sources.count) excerpts · \(manifest.omissions.count) coverage notes", isExpanded: $sourcesExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(manifest.omissions.enumerated()), id: \.offset) { _, omission in
                                Text(omission.detail).font(.caption).foregroundStyle(.orange)
                            }
                            ForEach(manifest.sources, id: \.id) { source in
                                Text("\(source.relativePath):\(source.startLine)–\(source.endLine)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    }
                }
            }.padding(28).frame(maxWidth: 1000, alignment: .leading)
        }
    }
}
