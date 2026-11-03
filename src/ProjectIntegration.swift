import AppKit
import Foundation

@available(macOS 26.0, *)
extension AppModel {
    var selectedProject: ProjectProfile? { projects.first { $0.id == selectedProjectID } }

    var currentProjectPacket: PreparedPacket? {
        guard !preparation.isPreparing, preparation.error == nil,
              let packet = preparation.packet, packet.projectID == selectedProjectID else { return nil }
        return packet
    }

    func reloadProjects() {
        do { projects = try projectStore.list() }
        catch { errorText = "Could not read projects: \(error.localizedDescription)" }
    }

    func createProject(name: String, root: URL) {
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "MeetingScribe is updating. Try again after it reopens."
            return
        }
        guard phase == .idle else { return }
        do {
            let project = try projectStore.create(name: name, root: root)
            reloadProjects()
            openProject(project.id)
        } catch { errorText = error.localizedDescription }
    }

    func openProject(_ id: UUID) {
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "MeetingScribe is updating. Try again after it reopens."
            return
        }
        guard phase == .idle, let project = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        route = .project(id)
        preparation.prepare(project)
        Task { await prepareModel() }
    }

    func refreshProject() {
        guard !AppUpdater.shared.installationInProgress else {
            errorText = "MeetingScribe is updating. Try again after it reopens."
            return
        }
        guard let project = selectedProject else { return }
        preparation.prepare(project)
    }

    func renameProject(_ project: ProjectProfile, to name: String) {
        guard phase == .idle else { return }
        do { _ = try projectStore.rename(id: project.id, name: name); reloadProjects() }
        catch { errorText = error.localizedDescription }
    }

    func relocateProject(_ project: ProjectProfile) {
        guard phase == .idle else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the new location for \(project.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preparation.cancel()
        do {
            _ = try projectStore.relocate(id: project.id, to: url)
            reloadProjects(); openProject(project.id)
        } catch { errorText = error.localizedDescription }
    }

    func archiveProject(_ project: ProjectProfile) {
        guard phase == .idle else { return }
        if selectedProjectID == project.id { preparation.cancel(); selectedProjectID = nil }
        do { try projectStore.archive(id: project.id); reloadProjects(); route = .projects }
        catch { errorText = error.localizedDescription }
    }

    func startProjectMeeting() {
        guard phase == .idle, let project = selectedProject else { return }
        var info = MeetingInfo()
        info.title = project.name
        info.materials = [project.rootPath]
        info.projectID = project.id
        info.preparedPacketID = currentProjectPacket?.id
        info.brief = currentProjectPacket.map { projectStore.briefURL(projectID: $0.projectID, packetID: $0.id).path }
        meeting = info
        Task { await start() }
    }

    func preparationChanged() {
        objectWillChange.send()
        guard isRecording, let packet = currentProjectPacket,
              packet.id != meeting.preparedPacketID else { return }
        meeting.preparedPacketID = packet.id
        meeting.brief = projectStore.briefURL(projectID: packet.projectID, packetID: packet.id).path
        live.replaceContext(packet)
        if let dir = sessionDir { SessionFiles(dir: dir).save(meeting: meeting) }
    }
}
