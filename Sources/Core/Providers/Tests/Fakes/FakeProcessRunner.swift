import Foundation
import Models
import Providers

/// A fake `ProcessRunning` implementation for tests.
/// Each call records the command and returns a pre-configured result.
/// The `handler` closure lets individual tests control exit codes and
/// what gets written to stdout/stderr files.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    /// Closure invoked for every `run(...)` call. Receives the command string
    /// and arguments, and must return a `ProcessResult`. It can also write
    /// content to the stdout/stderr file paths before returning.
    let handler: @Sendable (String, [String], String?, String?) -> ProcessResult

    /// The last timeout value passed to `run(...)`. Useful for verifying
    /// that providers forward timeout values to the process runner.
    private(set) var capturedTimeout: Int?

    /// The last `executablePath` value passed to `run(...)`. Non-nil indicates
    /// direct execution (no shell wrapping).
    private(set) var capturedExecutablePath: String?

    /// The last `arguments` array passed to `run(...)`.
    private(set) var capturedArguments: [String]?

    init(
        handler: @escaping @Sendable (String, [String], String?, String?) -> ProcessResult
    ) {
        self.handler = handler
    }

    /// Convenience initializer that returns a fixed exit code and
    /// optionally writes `stdoutContent` to the stdout file.
    init(exitCode: Int32 = 0, stdoutContent: String = "", stderrContent: String = "") {
        self.handler = { _, _, stdoutPath, stderrPath in
            if let stdoutPath, stdoutPath != "/dev/null" {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: stdoutContent.data(using: .utf8)
                )
            }
            if let stderrPath, stderrPath != "/dev/null" {
                FileManager.default.createFile(
                    atPath: stderrPath,
                    contents: stderrContent.data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: exitCode,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        }
    }

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
        capturedTimeout = timeout
        capturedExecutablePath = executablePath
        capturedArguments = arguments
        return handler(command, arguments, stdoutPath, stderrPath)
    }
}
