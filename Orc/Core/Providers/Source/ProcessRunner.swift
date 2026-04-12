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
            process.currentDirectoryPath = workingDirectory
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

    // MARK: - Streaming

    func runStreaming(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?,
        executablePath: String? = nil
    ) -> AsyncThrowingStream<ProcessStreamEvent, any Error> {
        let resolvedStdoutPath = stdoutPath ?? "/dev/null"
        let resolvedStderrPath = stderrPath ?? "/dev/null"

        return AsyncThrowingStream { continuation in
            let outerTask = Task { @Sendable [self] in
                let process = Process()

                // Configure executable (same as existing run())
                if let executablePath {
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: Platform.defaultShell)
                    process.arguments = ["-c", command]
                }

                if let workingDirectory {
                    process.currentDirectoryPath = workingDirectory
                }

                if let environment {
                    var merged = ProcessInfo.processInfo.environment
                    for (key, value) in environment { merged[key] = value }
                    process.environment = merged
                }

                // Create pipes for real-time streaming
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Create log files for persistence (same as non-streaming path)
                let stdoutFile: FileHandle?
                if resolvedStdoutPath != "/dev/null" {
                    FileManager.default.createFile(atPath: resolvedStdoutPath, contents: nil)
                    stdoutFile = FileHandle(forWritingAtPath: resolvedStdoutPath)
                } else {
                    stdoutFile = nil
                }

                let stderrFile: FileHandle?
                if resolvedStderrPath != "/dev/null" {
                    FileManager.default.createFile(atPath: resolvedStderrPath, contents: nil)
                    stderrFile = FileHandle(forWritingAtPath: resolvedStderrPath)
                } else {
                    stderrFile = nil
                }

                let timedOut = TimeoutFlag()

                // Set termination handler BEFORE run() to avoid race where the
                // process exits before the handler is installed.
                var timeoutTask: Task<Void, Never>?

                let exitStatus: Int32
                do {
                    exitStatus = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, any Error>) in
                        process.terminationHandler = { proc in
                            cont.resume(returning: proc.terminationStatus)
                        }
                        do {
                            try process.run()
                        } catch {
                            process.terminationHandler = nil
                            cont.resume(throwing: error)
                            return
                        }

                        // Start timeout timer after successful process launch
                        timeoutTask = timeout.map { seconds in
                            Task.detached {
                                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                                if process.isRunning {
                                    timedOut.set()
                                    self.terminateGracefully(process)
                                }
                            }
                        }

                        // Start pipe readers AFTER process.run() succeeds but BEFORE
                        // the continuation suspends waiting for the termination handler.
                        // This ensures data flows immediately. Using Task.detached with
                        // blocking availableData reads for cross-platform compatibility
                        // (readabilityHandler is broken on Linux).
                        Task.detached {
                            while true {
                                let data = stdoutPipe.fileHandleForReading.availableData
                                if data.isEmpty { break }  // EOF
                                stdoutFile?.write(data)
                                continuation.yield(.stdout(data))
                            }
                        }

                        Task.detached {
                            while true {
                                let data = stderrPipe.fileHandleForReading.availableData
                                if data.isEmpty { break }  // EOF
                                stderrFile?.write(data)
                                continuation.yield(.stderr(data))
                            }
                        }
                    }
                } catch {
                    stdoutFile?.closeFile()
                    stderrFile?.closeFile()
                    continuation.finish(throwing: error)
                    return
                }

                timeoutTask?.cancel()

                // Process has exited. Pipe readers will see EOF and exit their loops.
                // Brief sleep to let readers drain any final data from the pipe buffers.
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

                stdoutFile?.closeFile()
                stderrFile?.closeFile()

                if timedOut.value, let seconds = timeout {
                    continuation.finish(throwing: ProviderError.timeout(command: command, seconds: seconds))
                    return
                }

                let result = ProcessResult(
                    exitCode: exitStatus,
                    stdoutPath: resolvedStdoutPath,
                    stderrPath: resolvedStderrPath
                )
                continuation.yield(.completed(result))
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                outerTask.cancel()
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
