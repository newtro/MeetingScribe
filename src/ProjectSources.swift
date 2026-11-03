import Foundation
import Darwin

enum ProjectSourcePolicy {
    static let documentExtensions: Set<String> = ["md", "markdown", "txt"]
    static let codeExtensions: Set<String> = ["swift", "cs", "js", "jsx", "ts", "tsx", "py", "sql", "xml", "yaml", "yml", "json", "toml", "props", "csproj"]
    static let ignoredDirectories: Set<String> = [".git", "node_modules", "build", ".build", "dist", "deriveddata", "cache", "caches", ".cache", "__pycache__", "worktrees", ".worktrees", ".swiftpm", "bin", "obj", "secrets", "credentials", ".azure", ".aws", ".ssh", ".gnupg"]
    static func contains(_ url: URL, in root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
    static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        if path == base { return "." }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    static func excluded(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return true }
        if parts.contains(where: { ignoredDirectories.contains($0) }) { return true }
        if name.hasPrefix(".env") || name.hasSuffix(".local.json") { return true }
        if ["auth.json", "tokens.json", "token.json", "credentials.json", "credentials", ".npmrc", ".netrc", "id_rsa", "id_ed25519"].contains(name) { return true }
        if ["pem", "key", "p12", "pfx", "keystore", "cer"].contains((name as NSString).pathExtension) { return true }
        if name.hasPrefix("settings"), name.hasSuffix(".json"), parts.contains(where: { [".claude", ".codex", ".agents"].contains($0) }) { return true }
        if [".mcp.json", ".claude.json"].contains(name) { return true }
        if ["config.toml", "mcp.json"].contains(name), parts.contains(where: { [".claude", ".codex", ".agents"].contains($0) }) { return true }
        return false
    }
    static func isText(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return documentExtensions.contains(ext) || codeExtensions.contains(ext)
    }
    static func rank(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["agents.md", "claude.md", "memory.md"].contains(name) || name.hasPrefix("readme") { return 0 }
        if ["decision", "status", "meeting", "test", "uat", "report", "history", "handoff"].contains(where: { path.lowercased().contains($0) }) { return 2 }
        return documentExtensions.contains((path as NSString).pathExtension.lowercased()) ? 4 : 3
    }
    static func kind(path: String) -> SourceKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["agents.md", "claude.md"].contains(name) { return .guidance }
        if codeExtensions.contains((path as NSString).pathExtension.lowercased()) { return .implementation }
        // A filename does not establish approval, execution, or sent status.
        return .unknown
    }
}

struct CollectedSources: Sendable {
    var manifest: PreparationManifest
    var excerpts: [SourceExcerpt]
}

enum SourceText {
    struct Read { var data: Data; var modified: Date; var truncated: Bool }
    /// Validate the opened descriptor, not just a path checked before opening.
    /// Parent directories may change while a scan is in flight.
    static func read(_ url: URL, inside root: URL, limit: Int) throws -> Read {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ProjectFailure("Could not open source safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), named = stat()
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              fcntl(fd, F_GETPATH, &path) == 0,
              ProjectSourcePolicy.contains(URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath(), in: root) else {
            throw ProjectFailure("Source is not a regular file within the selected root.")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_ino == after.st_ino, named.st_dev == after.st_dev, named.st_mode & S_IFMT == S_IFREG else {
            throw ProjectFailure("Source changed while being read.")
        }
        return Read(data: data, modified: Date(timeIntervalSince1970: TimeInterval(before.st_mtimespec.tv_sec)), truncated: data.count > limit || before.st_size > limit)
    }
    static func utf8Prefix(_ data: Data, limit: Int) -> String? {
        var clipped = Data(data.prefix(max(0, limit)))
        for _ in 0...3 {
            if let s = String(data: clipped, encoding: .utf8) { return s }
            if clipped.isEmpty { break }; clipped.removeLast()
        }
        return nil
    }
    static func excerpt(path: String, text: String, hash: String? = nil, observed: Date = Date(), modified: Date? = nil,
                        kind: SourceKind, truncated: Bool = false, repoID: String? = nil, revision: String? = nil) -> SourceExcerpt {
        let digest = hash ?? ProjectHash.digest(text)
        let end = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let id = ProjectHash.digest("\(path)|\(digest)|1|\(end)|\(kind.rawValue)")
        return SourceExcerpt(source: SourceRecord(id: id, relativePath: path, contentHash: digest, startLine: 1, endLine: end,
            observedAt: observed, modifiedAt: modified, authoredAt: nil, kind: kind, repositoryID: repoID,
            revision: revision, environment: nil, truncated: truncated), text: text)
    }
}

/// Process arguments only. There is no shell, authentication, or repository mutation.
enum BoundedGitCommand {
    struct Result { var text: String; var code: Int32; var timedOut: Bool; var truncated: Bool }
    private final class Output: @unchecked Sendable {
        let lock = NSLock(); var data = Data(); var overflow = false
        func append(_ bytes: Data, cap: Int) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count > max(0, cap - data.count) { overflow = true }
            data.append(bytes.prefix(max(0, cap - data.count)))
        }
        func snapshot() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
    }
    static func run(at root: URL, _ args: [String], deadline: Date, cap: Int = 65_536) -> Result {
        guard deadline > Date(), !Task.isCancelled else { return Result(text: "", code: -1, timedOut: true, truncated: false) }
        let process = Process(), pipe = Pipe(), output = Output()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = env; process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData, cap: cap) }
        do { try process.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; return Result(text: "", code: -1, timedOut: false, truncated: false) }
        let end = min(deadline, Date().addingTimeInterval(2))
        var expired = false
        while process.isRunning {
            if Task.isCancelled || Date() >= end || output.snapshot().1 {
                expired = Date() >= end || Task.isCancelled
                process.terminate(); usleep(20_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(5_000)
        }
        let stop = Date().addingTimeInterval(0.2)
        while process.isRunning && Date() < stop { usleep(5_000) }
        pipe.fileHandleForReading.readabilityHandler = nil
        if !process.isRunning { output.append(pipe.fileHandleForReading.readDataToEndOfFile(), cap: cap) }
        try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
        let snapshot = output.snapshot()
        return Result(text: SourceText.utf8Prefix(snapshot.0, limit: cap) ?? "", code: process.isRunning ? -1 : process.terminationStatus, timedOut: expired, truncated: snapshot.1)
    }
}

enum GitCollector {
    static func collect(root: URL, scope: URL, deadline: Date, maxBytes: Int = 16_384) async -> GitSnapshot {
        await Task.detached(priority: .userInitiated) { collectSync(root: root, scope: scope, deadline: deadline, maxBytes: maxBytes) }.value
    }
    static func collectSync(root: URL, scope: URL, deadline: Date, maxBytes: Int = 16_384) -> GitSnapshot {
        let relative = ProjectSourcePolicy.relative(root, to: scope)
        let repoID = ProjectHash.digest(relative)
        let contentScope = ProjectSourcePolicy.contains(scope, in: root) ? ProjectSourcePolicy.relative(scope, to: root) : "."
        let scopeURL = ProjectSourcePolicy.contains(scope, in: root) ? scope : root
        func allowed(_ path: String) -> Bool {
            let url = root.appendingPathComponent(path).standardizedFileURL
            return ProjectSourcePolicy.contains(url, in: scopeURL) && !ProjectSourcePolicy.excluded(ProjectSourcePolicy.relative(url, to: scope)) && ProjectSourcePolicy.isText(path)
        }
        func worktreeFingerprint(_ paths: [String]) -> String {
            paths.sorted().map { path in
                var value = stat()
                guard lstat(root.appendingPathComponent(path).path, &value) == 0 else { return path + ":missing" }
                return "\(path):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
            }.joined(separator: "\n")
        }
        var omissions: [SourceOmission] = []
        func command(_ args: [String], required: Bool = true, cap: Int = 65_536) -> BoundedGitCommand.Result {
            let result = BoundedGitCommand.run(at: root, args, deadline: deadline, cap: cap)
            if result.timedOut || result.truncated || (required && result.code != 0) {
                omissions.append(SourceOmission(relativePath: relative, reason: result.timedOut ? .timeout : result.truncated ? .limit : .gitFailure, detail: "Local Git \(args.first ?? "query") was incomplete."))
            }
            return result
        }
        for attempt in 0...1 {
            let beforeHead = command(["rev-parse", "--verify", "HEAD"], required: false).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let beforeStatus = command(["status", "--porcelain=v2", "--branch", "-z", "--", contentScope])
            let branch = command(["symbolic-ref", "--short", "-q", "HEAD"], required: false).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let head: String? = beforeHead.isEmpty ? nil : beforeHead
            var sources: [SourceExcerpt] = []
            func add(_ name: String, _ text: String, truncated: Bool = false) {
                guard !text.isEmpty else { return }
                sources.append(SourceText.excerpt(path: "git/\(repoID)/\(name)", text: text, kind: .implementation, truncated: truncated, repoID: repoID, revision: head))
            }
            add("head", "Local repository: \(relative)\nHEAD: \(head ?? "No commits")\nBranch: \(branch.isEmpty ? "Detached" : branch)\nRemote tracking refs are local observations, not a network refresh.")
            let staged = command(["diff", "--cached", "--name-only", "-z", "--", contentScope]).text.split(separator: "\0").map(String.init).filter(allowed)
            let unstaged = command(["diff", "--name-only", "-z", "--", contentScope]).text.split(separator: "\0").map(String.init).filter(allowed)
            let untracked = command(["ls-files", "--others", "--exclude-standard", "-z", "--", contentScope]).text.split(separator: "\0").map(String.init).filter(allowed)
            let changed = Array(Set(staged + unstaged + untracked)).sorted()
            let beforeFiles = worktreeFingerprint(changed)
            // Never put raw porcelain records into the model: excluded filenames may occur there.
            add("status", "Staged allowed paths:\n" + staged.joined(separator: "\n") + "\nUnstaged allowed paths:\n" + unstaged.joined(separator: "\n") + "\nUntracked allowed paths:\n" + untracked.joined(separator: "\n"))
            if head != nil {
                let log = command(["log", "-20", "--date=iso-strict", "--format=%H %aI %s", "--", contentScope], cap: 8_192)
                add("log", log.text, truncated: log.truncated)
            }
            var remaining = maxBytes
            for (label, paths, cached) in [("diff-staged", staged, true), ("diff-unstaged", unstaged, false)] {
                let bounded = Array(paths.prefix(30))
                if bounded.count < paths.count { omissions.append(SourceOmission(relativePath: relative, reason: .limit, detail: "Only the first 30 changed paths per diff were included.")) }
                guard !bounded.isEmpty else { continue }
                guard remaining > 0 else { omissions.append(SourceOmission(relativePath: relative, reason: .limit, detail: "The Git patch byte budget was exhausted before all selected changes were included.")); continue }
                let statArgs = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--stat"] + (cached ? ["--cached"] : []) + ["--"] + bounded
                let statResult = command(statArgs, cap: 4_096)
                add(label + "-stat", statResult.text, truncated: statResult.truncated)
                let args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=2"] + (cached ? ["--cached"] : []) + ["--"] + bounded
                let patch = command(args, cap: remaining)
                add(label, patch.text, truncated: patch.truncated); remaining -= patch.text.utf8.count
            }
            let afterHead = command(["rev-parse", "--verify", "HEAD"], required: false).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let afterStatus = command(["status", "--porcelain=v2", "--branch", "-z", "--", contentScope])
            let stable = beforeHead == afterHead && beforeStatus.text == afterStatus.text && beforeFiles == worktreeFingerprint(changed)
                && beforeStatus.code == 0 && afterStatus.code == 0 && !beforeStatus.truncated && !afterStatus.truncated
            if !stable && attempt == 0 && Date().addingTimeInterval(1) < deadline { continue }
            if !stable { omissions.append(SourceOmission(relativePath: relative, reason: .unstable, detail: "Git changed during inspection; current-state excerpts withheld.")); sources = [] }
            let dirty = beforeStatus.text.split(separator: "\0").contains { !$0.hasPrefix("#") }
            return GitSnapshot(repositoryID: repoID, relativeRoot: relative, head: head, branch: branch.isEmpty ? nil : branch, detached: head != nil && branch.isEmpty, dirty: dirty, observedAt: Date(), stable: stable, sources: sources, omissions: omissions)
        }
        return GitSnapshot(repositoryID: repoID, relativeRoot: relative, head: nil, branch: nil, detached: false, dirty: false, observedAt: Date(), stable: false, sources: [], omissions: omissions)
    }
}

enum ProjectSourceCollector {
    private struct Candidate { let url: URL; let relative: String; let modified: Date; let rank: Int }
    /// Revalidate the captured evidence after inference. A complete answer based
    /// on changed/deleted inputs is not a fresh project generation.
    static func validateSnapshot(_ collected: CollectedSources, profile: ProjectProfile, deadline: Date) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            let root = try ProjectStore.canonicalDirectory(profile.rootURL)
            var seen = Set<String>()
            for excerpt in collected.excerpts where excerpt.source.repositoryID == nil {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ProjectFailure("Preparation deadline reached during source validation.") }
                guard seen.insert(excerpt.source.relativePath).inserted else { continue }
                let url = root.appendingPathComponent(excerpt.source.relativePath)
                let bytes = excerpt.text.utf8.count
                let read: SourceText.Read
                do { read = try SourceText.read(url, inside: root, limit: bytes) }
                catch { throw ProjectFailure("A project source changed or became unavailable during preparation. Refresh to build a current snapshot.") }
                guard let text = SourceText.utf8Prefix(read.data, limit: bytes), ProjectHash.digest(text) == excerpt.source.contentHash,
                      excerpt.source.truncated || !read.truncated else {
                    throw ProjectFailure("A project source changed during preparation. Refresh to build a current snapshot.")
                }
            }
            let gitDeadline = min(deadline, Date().addingTimeInterval(15))
            for snapshot in collected.manifest.git where snapshot.stable {
                try Task.checkCancellation()
                let repo = snapshot.relativeRoot.hasPrefix("/") ? URL(fileURLWithPath: snapshot.relativeRoot) : root.appendingPathComponent(snapshot.relativeRoot)
                let current = GitCollector.collectSync(root: repo, scope: root, deadline: gitDeadline, maxBytes: profile.limits.maxGitBytes)
                guard current.stable, current.head == snapshot.head, current.branch == snapshot.branch,
                      current.sources.map(\.text) == snapshot.sources.map(\.text) else {
                    throw ProjectFailure("Local Git evidence changed or became unavailable during preparation. Refresh to build a current snapshot.")
                }
            }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func collect(profile: ProjectProfile, generationID: UUID, deadline: Date,
                        onProgress: @escaping @Sendable (PreparationProgress) -> Void = { _ in }) async throws -> CollectedSources {
        let worker = Task.detached(priority: .userInitiated) { try collectSync(profile: profile, generationID: generationID, deadline: deadline, onProgress: onProgress) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func collectSync(profile: ProjectProfile, generationID: UUID, deadline: Date,
                                    onProgress: @escaping @Sendable (PreparationProgress) -> Void) throws -> CollectedSources {
        let started = Date(), root = try ProjectStore.canonicalDirectory(profile.rootURL), fm = FileManager.default, limits = profile.limits
        try limits.validate()
        let localDeadline = min(deadline, started.addingTimeInterval(45))
        var scanned = 0, excluded = 0, candidates: [Candidate] = [], repoRoots: [URL] = [], omissions: [SourceOmission] = []
        func check() throws { if Task.isCancelled { throw CancellationError() }; if Date() >= deadline { throw ProjectFailure("Preparation deadline reached.") } }
        func walk(_ directory: URL, depth: Int) throws {
            try check()
            guard scanned < limits.maxEntries, Date() < localDeadline else { return }
            let items: [URL]
            do { items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: []).sorted { $0.lastPathComponent < $1.lastPathComponent } }
            catch { omissions.append(SourceOmission(relativePath: ProjectSourcePolicy.relative(directory, to: root), reason: .unreadable, detail: "Directory could not be enumerated.")); return }
            for item in items {
                try check()
                guard scanned < limits.maxEntries, Date() < localDeadline else { return }
                scanned += 1
                let path = ProjectSourcePolicy.relative(item, to: root)
                if item.lastPathComponent == ".git" {
                    if depth <= limits.repositoryDepth, repoRoots.count < limits.maxRepositories {
                        let attrs = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if attrs?.isSymbolicLink != true, attrs?.isDirectory == true { repoRoots.append(directory) }
                        else if attrs?.isSymbolicLink != true, let read = try? SourceText.read(item, inside: root, limit: 4_096), !read.truncated,
                                let pointer = String(data: read.data, encoding: .utf8), pointer.hasPrefix("gitdir: ") {
                            let value = pointer.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                            let target = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : directory.appendingPathComponent(value)).standardizedFileURL.resolvingSymlinksInPath()
                            if ProjectSourcePolicy.contains(target, in: root) { repoRoots.append(directory) }
                            else { omissions.append(SourceOmission(relativePath: path, reason: .outsideRoot, detail: "Nested Git metadata points outside the project.")) }
                        }
                    } else { omissions.append(SourceOmission(relativePath: path, reason: .limit, detail: "Nested repository depth or repository-count limit reached.")) }
                    excluded += 1; continue
                }
                if ProjectSourcePolicy.excluded(path) { excluded += 1; continue }
                guard let attrs = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { omissions.append(SourceOmission(relativePath: path, reason: .unreadable, detail: "Could not inspect file.")); continue }
                if attrs.isSymbolicLink == true { omissions.append(SourceOmission(relativePath: path, reason: .outsideRoot, detail: "Symbolic links are not followed during automatic preparation.")); continue }
                if attrs.isDirectory == true {
                    if depth < limits.maxDepth { try walk(item, depth: depth + 1) }
                    else { omissions.append(SourceOmission(relativePath: path, reason: .limit, detail: "Directory-depth limit reached.")) }
                } else if ProjectSourcePolicy.isText(path) {
                    candidates.append(Candidate(url: item, relative: path, modified: attrs.contentModificationDate ?? .distantPast, rank: ProjectSourcePolicy.rank(path)))
                } else { omissions.append(SourceOmission(relativePath: path, reason: .unsupported, detail: "Not a supported UTF-8 document or source file.")) }
            }
        }
        try walk(root, depth: 0)
        if excluded > 0 { omissions.append(SourceOmission(relativePath: nil, reason: .excluded, detail: "\(excluded) excluded files or directories were not read.")) }
        if scanned >= limits.maxEntries { omissions.append(SourceOmission(relativePath: nil, reason: .limit, detail: "Enumeration stopped at \(limits.maxEntries) entries.")) }
        if Date() >= localDeadline { omissions.append(SourceOmission(relativePath: nil, reason: .timeout, detail: "Local refresh time budget reached.")) }
        onProgress(PreparationProgress(stage: .collecting, elapsed: Date().timeIntervalSince(started), deadline: deadline, entries: scanned, sources: 0))
        let gitDeadline = min(deadline, Date().addingTimeInterval(15))
        let top = BoundedGitCommand.run(at: root, ["rev-parse", "--show-toplevel"], deadline: gitDeadline)
        if top.code == 0 {
            let url = URL(fileURLWithPath: top.text.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            if ProjectSourcePolicy.contains(root, in: url), !repoRoots.contains(url) { repoRoots.insert(url, at: 0) }
        }
        if repoRoots.count > limits.maxRepositories { omissions.append(SourceOmission(relativePath: nil, reason: .limit, detail: "Repository-count limit reached.")) }
        var git: [GitSnapshot] = []
        for repo in repoRoots.prefix(limits.maxRepositories) {
            try check()
            guard Date() < gitDeadline else { omissions.append(SourceOmission(relativePath: nil, reason: .timeout, detail: "Git stage budget reached before all discovered repositories were inspected.")); break }
            let result = GitCollector.collectSync(root: repo, scope: root, deadline: gitDeadline, maxBytes: limits.maxGitBytes)
            git.append(result); omissions += result.omissions
        }
        let changedPaths = Set(git.flatMap(\.sources).filter { $0.source.relativePath.hasSuffix("/status") }.flatMap { $0.text.components(separatedBy: .newlines) })
        // Include notes regardless of Git ignore state. Code needs a change or an in-root reference.
        var selected = candidates.filter { ProjectSourcePolicy.documentExtensions.contains($0.url.pathExtension.lowercased()) || changedPaths.contains($0.relative) }
        // Changed paths are repo-relative; match each candidate against every discovered repo.
        for candidate in candidates where !selected.contains(where: { $0.relative == candidate.relative }) {
            if repoRoots.contains(where: { changedPaths.contains(ProjectSourcePolicy.relative(candidate.url, to: $0)) }) { selected.append(candidate) }
        }
        selected.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.modified != $1.modified ? $0.modified > $1.modified : $0.relative < $1.relative }
        if selected.count > limits.maxDocuments { omissions.append(SourceOmission(relativePath: nil, reason: .limit, detail: "Document count capped at \(limits.maxDocuments).")) }
        var excerpts: [SourceExcerpt] = [], total = 0
        var queue = Array(selected.prefix(limits.maxDocuments)), cursor = 0
        var queued = Set(queue.map(\.relative))
        let references = try NSRegularExpression(pattern: #"[A-Za-z0-9_./@-]+\.(?:md|markdown|txt|swift|cs|py|js|ts|tsx|jsx|sql|xml|yaml|yml|json|toml|props|csproj)"#)
        while cursor < queue.count && excerpts.count < limits.maxDocuments {
            guard Date() < localDeadline else { omissions.append(SourceOmission(relativePath: nil, reason: .timeout, detail: "Local extraction time budget reached.")); break }
            let candidate = queue[cursor]; cursor += 1
            try check()
            let bytes = min(limits.maxFileBytes, limits.maxTotalBytes - total)
            guard bytes > 0 else { omissions.append(SourceOmission(relativePath: nil, reason: .limit, detail: "Total source byte limit reached.")); break }
            let url = candidate.url
            guard ProjectSourcePolicy.contains(url.resolvingSymlinksInPath(), in: root) else { omissions.append(SourceOmission(relativePath: candidate.relative, reason: .outsideRoot, detail: "Path changed outside selected root.")); continue }
            do {
                let read = try SourceText.read(url, inside: root, limit: bytes), data = read.data
                guard !data.contains(0), let text = SourceText.utf8Prefix(data, limit: bytes) else { omissions.append(SourceOmission(relativePath: candidate.relative, reason: .unsupported, detail: "File is not UTF-8 text.")); continue }
                let truncated = read.truncated
                if truncated { omissions.append(SourceOmission(relativePath: candidate.relative, reason: .limit, detail: "File excerpt truncated at the byte limit.")) }
                total += text.utf8.count
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    excerpts.append(SourceText.excerpt(path: candidate.relative, text: text, modified: read.modified, kind: ProjectSourcePolicy.kind(path: candidate.relative), truncated: truncated))
                    let referenceText = String(text.prefix(32_768)) as NSString
                    for match in references.matches(in: referenceText as String, range: NSRange(location: 0, length: referenceText.length)).prefix(100) {
                        let ref = referenceText.substring(with: match.range)
                        let options = [root.appendingPathComponent(ref), candidate.url.deletingLastPathComponent().appendingPathComponent(ref)]
                        for target in options {
                            let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
                            guard ProjectSourcePolicy.contains(resolved, in: root) else {
                                omissions.append(SourceOmission(relativePath: nil, reason: .outsideRoot, detail: "A source references a file outside the selected project; it was not read.")); continue
                            }
                            let relative = ProjectSourcePolicy.relative(resolved, to: root)
                            guard !queued.contains(relative), !ProjectSourcePolicy.excluded(relative), let found = candidates.first(where: { $0.relative == relative }) else { continue }
                            if queue.count < limits.maxDocuments { queue.insert(found, at: cursor); queued.insert(relative) }
                            else { omissions.append(SourceOmission(relativePath: relative, reason: .limit, detail: "Referenced source exceeds document limit.")) }
                        }
                    }
                }
            } catch {
                let detail = (error as? ProjectFailure)?.message ?? "File could not be read safely."
                omissions.append(SourceOmission(relativePath: candidate.relative, reason: detail.contains("changed while") ? .unstable : .unreadable, detail: detail))
            }
        }
        excerpts += git.flatMap(\.sources)
        return CollectedSources(manifest: PreparationManifest(projectID: profile.id, generationID: generationID, startedAt: started,
            observedThrough: Date(), rootPath: root.path, entriesScanned: scanned, sources: excerpts.map(\.source), omissions: omissions,
            git: git, limits: limits, completed: true), excerpts: excerpts)
    }
}
