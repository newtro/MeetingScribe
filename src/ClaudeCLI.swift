import Foundation

/// Locating and running the `claude` CLI. Shared by the advisor, the brief builder and the summarizer.
enum ClaudeCLI {
    static let candidates = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// Settings override, else the first installed candidate.
    static var path: String {
        if let p = UserDefaults.standard.string(forKey: Prefs.claudePath), !p.isEmpty { return p }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A running CLI invocation whose stdout is delivered line by line. `cancel()` terminates it.
    final class Run: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
            if process.isRunning { process.terminate() }
        }

        /// Runs to completion. Returns stdout; throws on launch failure, non-zero exit, timeout or cancel.
        func run(args: [String], cwd: URL, stdin: String, timeout: TimeInterval,
                 onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    process.executableURL = URL(fileURLWithPath: ClaudeCLI.path)
                    process.arguments = args
                    process.currentDirectoryURL = cwd
                    process.environment = ClaudeCLI.environment
                    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                    process.standardInput = inPipe
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    let buf = LineBuffer(onLine: onLine)
                    outPipe.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        if !d.isEmpty { buf.append(d) }
                    }
                    var errData = Data()
                    let errDone = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }

                    do { try process.run() } catch {
                        cont.resume(throwing: Failure(message: "can't launch claude at \(ClaudeCLI.path): \(error.localizedDescription)"))
                        return
                    }
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                        try? inPipe.fileHandleForWriting.close()
                    }
                    var timedOut = false
                    let killer = DispatchWorkItem { [self] in
                        if process.isRunning { timedOut = true; process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                    process.waitUntilExit()
                    killer.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    buf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    buf.finish()
                    _ = errDone.wait(timeout: .now() + 2)

                    if lock.withLock({ cancelled }) {
                        cont.resume(throwing: CancellationError())
                    } else if timedOut {
                        cont.resume(throwing: Failure(message: "timed out after \(Int(timeout))s"))
                    } else if process.terminationStatus != 0 {
                        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        cont.resume(throwing: Failure(message: "claude exited \(process.terminationStatus): \(err.prefix(300))"))
                    } else {
                        cont.resume(returning: buf.text)
                    }
                }
            }
        }
    }

    /// Accumulates stdout and hands out complete lines.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var all = Data()
        private var pending = Data()
        private let onLine: (@Sendable (String) -> Void)?
        init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

        var text: String { lock.withLock { String(decoding: all, as: UTF8.self) } }

        func append(_ d: Data) {
            let lines: [String] = lock.withLock {
                all.append(d)
                pending.append(d)
                var out: [String] = []
                while let nl = pending.firstIndex(of: 0x0A) {
                    out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...nl)
                }
                return out
            }
            lines.forEach { onLine?($0) }
        }

        func finish() {
            let last: String? = lock.withLock {
                defer { pending.removeAll() }
                return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
            }
            if let last { onLine?(last) }
        }
    }
}

/// UserDefaults keys, shared by @AppStorage in the views and by non-UI code.
enum Prefs {
    static let userName = "userName"
    static let claudePath = "claudePath"
    static let advisorInterval = "advisorInterval"
    static let autoSummary = "autoSummary"
    static let briefModel = "briefModel"

    static var user: String {
        let s = UserDefaults.standard.string(forKey: userName)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !s.isEmpty { return s }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "the user"
    }
}
