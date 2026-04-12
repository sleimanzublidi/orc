import Foundation
import Logging
import Models

// MARK: - ProcessRunner

/// Thin wrapper around Foundation's `Process` that conforms to `ProcessRunning`.
/// Executes commands via the platform default shell with optional timeout enforcement.
struct ProcessRunner: ProcessRunning, Sendable {
    private let logger = Logger(label: "orc.providers.process-runner")

    init() {}

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?,
        executablePath: String? = nil
    ) async throws -> ProcessResult {
        let resolvedStdoutPath = stdoutPath ?? "/dev/null"
        let resolvedStderrPath = stderrPath ?? "/dev/null"

        let process = Process()

        if let executablePath {
            // Direct execution: bypass the shell entirely. The executable is
            // invoked with the supplied arguments as its argv, so no shell
            // metacharacter interpretation occurs. This eliminates
            // shell-string injection for known binaries.
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
        } else {
            // Legacy shell mode: wrap the command string in the default shell's -c.
            // Use this only for user-supplied shell commands that need shell
            // features (pipes, redirects, variable expansion, etc.).
            process.executableURL = URL(fileURLWithPath: Platform.defaultShell)
            process.arguments = ["-c", command]
        }

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        // Merge caller-supplied env vars into the current process environment
        // so the child inherits PATH and other essentials.
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        // Redirect stdout
        if resolvedStdoutPath == "/dev/null" {
            process.standardOutput = FileHandle.nullDevice
        } else {
            FileManager.default.createFile(atPath: resolvedStdoutPath, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: resolvedStdoutPath) else {
                throw ProviderError.processFailure(
                    command: command,
                    exitCode: -1,
                    stderr: "Failed to open stdout path: \(resolvedStdoutPath)"
                )
            }
            process.standardOutput = handle
        }

        // Redirect stderr
        if resolvedStderrPath == "/dev/null" {
            process.standardError = FileHandle.nullDevice
        } else {
            FileManager.default.createFile(atPath: resolvedStderrPath, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: resolvedStderrPath) else {
                throw ProviderError.processFailure(
                    command: command,
                    exitCode: -1,
                    stderr: "Failed to open stderr path: \(resolvedStderrPath)"
                )
            }
            process.standardError = handle
        }

        // Thread-safe flag so we can distinguish "our timeout killed it"
        // from "the process happened to exit with a signal-like code."
        let timedOut = TimeoutFlag()

        return try await withTaskCancellationHandler {
            // Set terminationHandler BEFORE run() to eliminate the race where
            // the process exits before the handler is installed. Foundation's
            // dispatch source checks terminationHandler exactly once on exit —
            // if it's nil at that moment, the callback is lost and the
            // continuation never resumes.
            var timeoutTask: Task<Void, Never>?

            let exitStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                // Start timeout timer after successful process launch.
                timeoutTask = timeout.map { seconds in
                    Task.detached {
                        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                        if process.isRunning {
                            timedOut.set()
                            self.terminateGracefully(process)
                        }
                    }
                }
            }

            let result = ProcessResult(
                exitCode: exitStatus,
                stdoutPath: resolvedStdoutPath,
                stderrPath: resolvedStderrPath
            )

            timeoutTask?.cancel()

            // Use the flag -- not exit-code heuristics -- to detect timeout.
            if timedOut.value, let seconds = timeout {
                throw ProviderError.timeout(command: command, seconds: seconds)
            }

            return result
        } onCancel: {
            // On task cancellation, gracefully shut down the process.
            if process.isRunning {
                terminateGracefully(process)
            }
        }
    }

    /// Sends SIGTERM, waits 5 seconds, then sends SIGKILL if the process is still alive.
    private func terminateGracefully(_ process: Process) {
        process.terminate()  // SIGTERM
        Task.detached {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

// MARK: - TimeoutFlag

/// Thread-safe boolean flag for tracking whether a timeout occurred.
/// Used to distinguish "our timeout killed the process" from "process
/// happened to exit with a signal-like code."
private final class TimeoutFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        _value = true
    }
}
