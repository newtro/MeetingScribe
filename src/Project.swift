import Foundation
import CryptoKit

struct ProjectFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct SourceLimits: Codable, Equatable, Sendable {
    var maxEntries = 5_000
    var maxDepth = 12
    var maxDocuments = 200
    var maxFileBytes = 1_048_576
    var maxTotalBytes = 12 * 1_048_576
    var maxPacketBytes = 80 * 1_024
    var maxRepositories = 8
    var repositoryDepth = 4
    var maxGitBytes = 16 * 1_024
    var preparationSeconds: Double = 300

    func validate() throws {
        let defaults = SourceLimits()
        let pairs = [(maxEntries, defaults.maxEntries), (maxDepth, defaults.maxDepth),
                     (maxDocuments, defaults.maxDocuments), (maxFileBytes, defaults.maxFileBytes),
                     (maxTotalBytes, defaults.maxTotalBytes), (maxPacketBytes, defaults.maxPacketBytes),
                     (maxRepositories, defaults.maxRepositories), (repositoryDepth, defaults.repositoryDepth),
                     (maxGitBytes, defaults.maxGitBytes)]
        guard pairs.allSatisfy({ $0.0 > 0 && $0.0 <= $0.1 * 10 }),
              preparationSeconds >= 60, preparationSeconds <= 300 else {
            throw ProjectFailure("Source limits must be positive, at most ten times the defaults; preparation must finish in 60–300 seconds.")
        }
    }
}

struct ProjectProfile: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var rootPath: String
    var createdAt = Date()
    var lastOpenedAt: Date?
    var limits = SourceLimits()
    var archived = false
    var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
}

enum SourceKind: String, Codable, Sendable {
    case guidance, requirement, implementation, executionReport, proposal, conversation, unknown
}

struct SourceRecord: Codable, Identifiable, Sendable {
    var id: String
    var relativePath: String
    var contentHash: String
    var startLine: Int
    var endLine: Int
    var observedAt: Date
    var modifiedAt: Date?
    var authoredAt: String?
    var kind: SourceKind
    var repositoryID: String?
    var revision: String?
    var environment: String?
    var truncated: Bool
    var lineStart: Int { startLine }
    var lineEnd: Int { endLine }
}

struct SourceExcerpt: Codable, Sendable {
    var source: SourceRecord
    var text: String
}

enum OmissionReason: String, Codable, Sendable {
    case excluded, unsupported, limit, unreadable, outsideRoot, unstable, timeout, gitFailure
}

struct SourceOmission: Codable, Sendable {
    var relativePath: String?
    var reason: OmissionReason
    var detail: String
}

struct GitSnapshot: Codable, Sendable {
    var repositoryID: String
    var relativeRoot: String
    var head: String?
    var branch: String?
    var detached: Bool
    var dirty: Bool
    var observedAt: Date
    var stable: Bool
    var sources: [SourceExcerpt]
    var omissions: [SourceOmission]
}

struct PreparationManifest: Codable, Sendable {
    var schemaVersion = 1
    var projectID: UUID
    var generationID: UUID
    var startedAt: Date
    var observedThrough: Date
    var rootPath: String
    var entriesScanned: Int
    var sources: [SourceRecord]
    var omissions: [SourceOmission]
    var git: [GitSnapshot]
    var limits: SourceLimits
    var completed: Bool
    var hasCoverageLimits: Bool { omissions.contains { $0.reason != .excluded } }
}

enum ClaimKind: String, Codable, Sendable { case fact, reported, proposal }
enum ClaimScope: String, Codable, Sendable { case sourceContent, reportedOutcome, suggestedAction }
enum TopicPriority: String, Codable, Sendable { case attention, discussion, background }

struct EvidenceClaim: Codable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var kind: ClaimKind
    var scope: ClaimScope
    var sourceIDs: [String]
    /// One quote per source ID, in the same order.
    var quotes: [String]
    var environment: String?
    var dateQualifier: String?
}

struct PreparedTopic: Codable, Sendable {
    var key: String
    var title: String
    var claimIDs: [UUID]
    var priority: TopicPriority
    var reason: String
}

struct PreparedPacket: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var projectID: UUID
    var preparedAt: Date
    var manifestID: UUID
    var projectSummary: String
    var claims: [EvidenceClaim]
    var topics: [PreparedTopic]
    var openQuestions: [String]
    var coverageNotes: [String]
    var briefMarkdown: String
    var model: ModelReceipt
}

struct LatestPacketPointer: Codable {
    var schemaVersion = 1
    var projectID: UUID
    var generationID: UUID
}

enum ProjectHash {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
}

/// All writes are confined to the application data root. No source-folder writes.
final class ProjectStore: @unchecked Sendable {
    let root: URL
    private let lock = NSRecursiveLock()
    init(root: URL = Paths.root) { self.root = root }
    var projectsRoot: URL { root.appendingPathComponent("projects", isDirectory: true) }
    func directory(for id: UUID) -> URL { projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func packetDirectory(projectID: UUID, generationID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("packets", isDirectory: true).appendingPathComponent(generationID.uuidString, isDirectory: true)
    }
    func briefURL(for packet: PreparedPacket) -> URL {
        packetDirectory(projectID: packet.projectID, generationID: packet.id).appendingPathComponent("brief.md")
    }
    func briefURL(projectID: UUID, packetID: UUID) -> URL {
        packetDirectory(projectID: projectID, generationID: packetID).appendingPathComponent("brief.md")
    }
    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    static func canonicalDirectory(_ url: URL) throws -> URL {
        let result = url.standardizedFileURL.resolvingSymlinksInPath()
        let attrs = try result.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard attrs.isDirectory == true, attrs.isReadable == true else { throw ProjectFailure("Choose an existing readable project folder.") }
        return result
    }
    func list(includeArchived: Bool = false) throws -> [ProjectProfile] {
        try serialized {
            guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [] }
            let dirs = try FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)
            return try dirs.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map {
                try read(ProjectProfile.self, $0.appendingPathComponent("profile.json"))
            }.filter { includeArchived || !$0.archived }.sorted {
                if $0.lastOpenedAt != $1.lastOpenedAt { return ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }
    func profile(id: UUID) throws -> ProjectProfile { try serialized { try read(ProjectProfile.self, directory(for: id).appendingPathComponent("profile.json")) } }
    func create(name: String, root: URL) throws -> ProjectProfile {
        try serialized {
            let folder = try Self.canonicalDirectory(root)
            if var existing = try list(includeArchived: true).first(where: { $0.rootURL.standardizedFileURL.resolvingSymlinksInPath() == folder }) {
                if existing.archived { existing.archived = false; try save(existing) }
                return existing
            }
            let value = ProjectProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), rootPath: folder.path)
            try save(value); return value
        }
    }
    func save(_ profile: ProjectProfile) throws {
        try serialized {
            guard profile.schemaVersion == 1, (1...100).contains(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw ProjectFailure("Project names need 1–100 characters.") }
            try profile.limits.validate()
            let dir = directory(for: profile.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write(profile, dir.appendingPathComponent("profile.json"))
        }
    }
    @discardableResult func rename(id: UUID, name: String) throws -> ProjectProfile {
        try serialized { var p = try profile(id: id); p.name = name.trimmingCharacters(in: .whitespacesAndNewlines); try save(p); return p }
    }
    @discardableResult func relocate(id: UUID, to url: URL) throws -> ProjectProfile {
        try serialized { var p = try profile(id: id); p.rootPath = try Self.canonicalDirectory(url).path; p.lastOpenedAt = nil; try save(p); return p }
    }
    func archive(id: UUID) throws { try serialized { var p = try profile(id: id); p.archived = true; try save(p) } }
    func latest(for id: UUID) throws -> PreparedPacket? {
        try serialized {
            let url = directory(for: id).appendingPathComponent("latest.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let pointer = try read(LatestPacketPointer.self, url)
            guard pointer.projectID == id, pointer.schemaVersion == 1 else { throw ProjectFailure("Invalid project packet pointer.") }
            let p = try read(PreparedPacket.self, packetDirectory(projectID: id, generationID: pointer.generationID).appendingPathComponent("packet.json"))
            guard p.projectID == id, p.id == pointer.generationID else { throw ProjectFailure("Project packet identity mismatch.") }
            let m = try manifest(for: p)
            guard m.rootPath == (try profile(id: id)).rootPath else { return nil }
            return p
        }
    }
    func manifest(for packet: PreparedPacket) throws -> PreparationManifest {
        try serialized { try read(PreparationManifest.self, packetDirectory(projectID: packet.projectID, generationID: packet.id).appendingPathComponent("manifest.json")) }
    }
    func excerpts(for packet: PreparedPacket) throws -> [SourceExcerpt] {
        try serialized { try read([SourceExcerpt].self, packetDirectory(projectID: packet.projectID, generationID: packet.id).appendingPathComponent("excerpts.json")) }
    }
    func publish(packet: PreparedPacket, manifest: PreparationManifest, excerpts: [SourceExcerpt]) throws {
        try serialized {
            guard packet.projectID == manifest.projectID, packet.id == manifest.generationID,
                  packet.manifestID == manifest.generationID, manifest.completed else { throw ProjectFailure("Incomplete or mismatched preparation cannot be published.") }
            try PacketValidator.validateClaims(packet.claims, excerpts: excerpts)
            let parent = directory(for: packet.projectID).appendingPathComponent("packets", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let destination = packetDirectory(projectID: packet.projectID, generationID: packet.id)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProjectFailure("Prepared packets are immutable.") }
            let staging = parent.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            try write(packet, staging.appendingPathComponent("packet.json"))
            try write(manifest, staging.appendingPathComponent("manifest.json"))
            try write(excerpts, staging.appendingPathComponent("excerpts.json"))
            try Data(packet.briefMarkdown.utf8).write(to: staging.appendingPathComponent("brief.md"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
            try write(LatestPacketPointer(projectID: packet.projectID, generationID: packet.id), directory(for: packet.projectID).appendingPathComponent("latest.json"))
        }
    }
    func checkWritable() throws {
        try serialized {
            try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            let probe = projectsRoot.appendingPathComponent(".probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: probe) }
            try Data("storage check".utf8).write(to: probe, options: .atomic)
        }
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(value).write(to: url, options: .atomic)
    }
}

enum PacketValidator {
    static func validateClaims(_ claims: [EvidenceClaim], excerpts: [SourceExcerpt]) throws {
        guard claims.count <= 40, Set(claims.map(\.id)).count == claims.count else { throw ProjectFailure("Invalid number or identity of claims.") }
        let sources = sourceIndex(excerpts)
        for c in claims { try validate(c, sources: sources) }
    }

    static func sourceIndex(_ excerpts: [SourceExcerpt]) -> [String: SourceExcerpt] {
        Dictionary(excerpts.map { ($0.source.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// One claim's own evidence and bounds. Claims stand alone, so a failing claim can be omitted without
    /// weakening any other claim's support.
    static func validate(_ c: EvidenceClaim, sources: [String: SourceExcerpt]) throws {
        guard !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              c.text.split(whereSeparator: \.isWhitespace).count <= 100,
              c.sourceIDs.count == c.quotes.count, c.sourceIDs.count <= 8 else { throw ProjectFailure("A claim exceeded its evidence or length bounds.") }
        let expected: ClaimScope = c.kind == .fact ? .sourceContent : c.kind == .reported ? .reportedOutcome : .suggestedAction
        guard c.scope == expected else { throw ProjectFailure("Claim status and scope disagree.") }
        if c.sourceIDs.isEmpty {
            guard c.kind == .proposal, c.text.contains("?"), c.text.lowercased().contains("unverified") else { throw ProjectFailure("An unsupported proposal must be an explicitly unverified investigation question.") }
        }
        for (id, quote) in zip(c.sourceIDs, c.quotes) {
            guard let source = sources[id], !quote.isEmpty, source.text.contains(quote) else { throw ProjectFailure("A claim contains an unknown source or a quote not present in that source.") }
        }
    }
}
