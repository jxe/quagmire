#if os(macOS)
import Darwin
import Foundation
import Quagmire

/// Runs Filter Through Command's command in the user's login shell, so a
/// Homebrew PATH from `.zprofile` applies, the way TextMate does.
public enum ShellFilterCommand {
    public enum Failure: LocalizedError, Equatable {
        case exited(status: Int32, stderr: String)
        case timedOut(seconds: Int)

        public var errorDescription: String? {
            switch self {
            case .exited(let status, let stderr):
                stderr.isEmpty ? "The command exited with status \(status)." : stderr
            case .timedOut(let seconds):
                "The command didn't finish within \(seconds) seconds."
            }
        }
    }

    public static func runner(
        shell: String = "/bin/zsh",
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeoutSeconds: Int = 10
    ) -> FilterCommandRunner {
        { command, stdin in
            try await run(
                command,
                stdin: stdin,
                shell: shell,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    public static func run(
        _ command: String,
        stdin: String,
        shell: String = "/bin/zsh",
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeoutSeconds: Int = 10
    ) async throws -> String {
        let job = Job(command: command, shell: shell, workingDirectory: workingDirectory)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try job.run(stdin: stdin, timeoutSeconds: timeoutSeconds)
                    })
                }
            }
        } onCancel: {
            job.terminate()
        }
    }

    /// One process run. Blocking; called off the main actor.
    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let errors = Pipe()
        private let lock = NSLock()
        private var timedOut = false
        private var stderrData = Data()

        init(command: String, shell: String, workingDirectory: URL) {
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = workingDirectory
            var environment = ProcessInfo.processInfo.environment
            if environment["LANG"] == nil, environment["LC_ALL"] == nil {
                environment["LANG"] = "en_US.UTF-8"
            }
            process.environment = environment
        }

        /// Stops the shell and its direct children, which may otherwise keep
        /// stdout open after the shell exits.
        func terminate() {
            guard process.isRunning else { return }
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
            try? pkill.run()
            pkill.waitUntilExit()
            process.terminate()
        }

        func run(stdin: String, timeoutSeconds: Int) throws -> String {
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // A command that never reads stdin closes the pipe early; report
            // EPIPE to the writer instead of raising SIGPIPE in the app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try process.run()

            let timeout = DispatchWorkItem { [self] in
                lock.withLock { timedOut = true }
                terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeout)
            defer { timeout.cancel() }

            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) { [self] in
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            DispatchQueue.global().async(group: group) { [self] in
                stderrData = errors.fileHandleForReading.readDataToEndOfFile()
            }
            let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()

            if lock.withLock({ timedOut }) {
                throw Failure.timedOut(seconds: timeoutSeconds)
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                let message = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.exited(status: process.terminationStatus, stderr: message)
            }
            return String(decoding: stdoutData, as: UTF8.self)
        }
    }
}
#endif
