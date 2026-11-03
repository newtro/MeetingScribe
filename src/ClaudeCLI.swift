import Foundation
import Darwin

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
        /// Internal bounded protocol output; never included in user-facing error descriptions.
        let stdout: String?
        init(message: String, stdout: String? = nil) { self.message = message; self.stdout = stdout }
        var errorDescription: String? { message }
    }

    /// A single owned process. Pipe draining and deadlines share one bounded polling loop.
    final class Run: @unchecked Sendable {
        struct Result: Sendable {
            let stdout: String
            let stderr: String
            let exitCode: Int32
            let elapsed: TimeInterval
        }
        private let process = Process()
        private let lock = NSLock()
        private var cancelled = false
        private var started = false
        private var finished = false
        private let executableURL: URL?
        private let childEnvironment: [String: String]?

        init(executableURL: URL? = nil, environment: [String: String]? = nil) {
            self.executableURL = executableURL; childEnvironment = environment
        }

        func cancel() { lock.withLock { cancelled = true } }

        func cancelAndWait() async {
            cancel()
            while lock.withLock({ started && !finished }) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        func run(args: [String], cwd: URL, stdin: String, timeout: TimeInterval,
                 onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
            try await run(args: args, cwd: cwd, stdin: stdin, deadline: Date().addingTimeInterval(timeout),
                          stdoutLimit: 4 * 1_024 * 1_024, onLine: onLine).stdout
        }

        func run(args: [String], cwd: URL, stdin: String, deadline: Date, stdoutLimit: Int = 1_048_576,
                 stderrLimit: Int = 65_536, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do { continuation.resume(returning: try execute(args: args, cwd: cwd, stdin: stdin,
                                                                      deadline: deadline, stdoutLimit: stdoutLimit,
                                                                      stderrLimit: stderrLimit, onLine: onLine)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }, onCancel: { self.cancel() })
        }

        private func execute(args: [String], cwd: URL, stdin: String, deadline: Date, stdoutLimit: Int,
                             stderrLimit: Int, onLine: (@Sendable (String) -> Void)?) throws -> Result {
            let began = Date()
            guard stdoutLimit > 0, stderrLimit > 0 else { throw Failure(message: "Invalid process output limit.") }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            defer {
                for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                               output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] {
                    try? handle.close()
                }
                lock.withLock { finished = true }
            }
            process.executableURL = executableURL ?? URL(fileURLWithPath: ClaudeCLI.path)
            process.arguments = args; process.currentDirectoryURL = cwd
            process.environment = childEnvironment ?? ClaudeCLI.environment
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                guard !started else { throw Failure(message: "A CLI runner can only be launched once.") }
                guard deadline > Date() else { throw Failure(message: "timed out before process launch") }
                started = true
                do { try process.run() }
                catch { throw Failure(message: "Cannot launch Claude CLI: \(error.localizedDescription)") }
            }
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            let inFD = input.fileHandleForWriting.fileDescriptor
            let outFD = output.fileHandleForReading.fileDescriptor
            let errFD = errors.fileHandleForReading.fileDescriptor
            for fd in [inFD, outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
            _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
            let inputData = Data(stdin.utf8)
            var inputOffset = 0, inputOpen = true, outOpen = true, errOpen = true
            var out = Data(), err = Data(), pending = Data()
            var failure: Error?, terminationAt: Date?, exitAt: Date?
            var sentKill = false
            func drain(_ fd: Int32, into data: inout Data, limit: Int, stdout: Bool) -> Bool {
                var bytes = [UInt8](repeating: 0, count: 8192)
                // A continuously writing child cannot starve cancellation/deadline checks.
                for _ in 0..<32 {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count == 0 { return false }
                    if count < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
                    let available = max(0, limit - data.count), take = min(available, count)
                    if take > 0 {
                        data.append(contentsOf: bytes.prefix(take))
                        if stdout, onLine != nil {
                            pending.append(contentsOf: bytes.prefix(take))
                            while let newline = pending.firstIndex(of: 10) {
                                onLine?(String(decoding: pending[..<newline], as: UTF8.self))
                                pending.removeSubrange(...newline)
                            }
                        }
                    }
                    if take < count, failure == nil { failure = Failure(message: "CLI output exceeded the bounded \(stdout ? "stdout" : "stderr") limit.") }
                }
                return true
            }
            while true {
                let now = Date()
                if lock.withLock({ cancelled }) { failure = CancellationError() }
                if now >= deadline, failure == nil { failure = Failure(message: "timed out after \(Int(now.timeIntervalSince(began)))s") }
                if failure != nil, terminationAt == nil {
                    terminationAt = now
                    if process.isRunning { process.terminate() }
                }
                if let terminationAt, now.timeIntervalSince(terminationAt) >= 2, !sentKill {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    sentKill = true
                }
                if outOpen { outOpen = drain(outFD, into: &out, limit: stdoutLimit, stdout: true) }
                if errOpen { errOpen = drain(errFD, into: &err, limit: stderrLimit, stdout: false) }
                if inputOpen {
                    if inputOffset < inputData.count, failure == nil {
                        let wrote = inputData.withUnsafeBytes { raw -> Int in
                            guard let address = raw.baseAddress else { return 0 }
                            return Darwin.write(inFD, address.advanced(by: inputOffset), min(8192, inputData.count - inputOffset))
                        }
                        if wrote > 0 { inputOffset += wrote }
                        else if wrote < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            try? input.fileHandleForWriting.close(); inputOpen = false
                        }
                    }
                    if inputOffset >= inputData.count || failure != nil {
                        try? input.fileHandleForWriting.close(); inputOpen = false
                    }
                }
                if !process.isRunning {
                    if exitAt == nil { exitAt = now }
                    // Descendants retaining a pipe must not prevent completion.
                    if (!outOpen && !errOpen) || now.timeIntervalSince(exitAt!) >= 0.25 { break }
                }
                if let terminationAt, now.timeIntervalSince(terminationAt) >= 3.0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let failure { throw failure }
            guard !process.isRunning else { throw Failure(message: "CLI did not exit within its termination deadline.") }
            process.waitUntilExit()
            if !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)) }
            guard process.terminationStatus == 0 else {
                // Do not echo stderr: provider errors may contain source or prompt material.
                throw Failure(message: "Claude CLI exited with status \(process.terminationStatus).", stdout: String(decoding: out, as: UTF8.self))
            }
            return Result(stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self),
                          exitCode: process.terminationStatus, elapsed: Date().timeIntervalSince(began))
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
