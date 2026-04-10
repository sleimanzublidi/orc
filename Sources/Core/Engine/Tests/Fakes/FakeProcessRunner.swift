import Foundation
import Models

/// A fake `ProcessRunning` implementation for Engine tests.
/// Records commands and returns pre-configured results for testing
/// script-type evaluators and other process-dependent logic.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    /// Closure invoked for every `run(...)` call. Receives the command, arguments,
    /// environment, and stdout/stderr paths. Returns a `ProcessResult`.
    var handler: @Sendable (String, [String], [String: String]?, String?, String?) -> ProcessResult

    /// Records all commands that were executed, in order.
    private(set) var executedCommands: [String] = []

    /// Records all environment dictionaries passed to run calls, in order.
    private(set) var executedEnvironments: [[String: String]?] = []

    /// Records all executable paths passed to run calls, in order.
    /// Non-nil entries indicate direct execution (no shell wrapping).
    private(set) var executedExecutablePaths: [String?] = []

    /// Records all argument arrays passed to run calls, in order.
    private(set) var executedArguments: [[String]] = []

    /// The last timeout value passed to `run(...)`. Useful for verifying
    /// that callers forward timeout values to the process runner.
    private(set) var capturedTimeout: Int?

    init(exitCode: Int32 = 0) {
        self.handler = { _, _, _, stdoutPath, stderrPath in
            ProcessResult(
                exitCode: exitCode,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        }
    }

    init(handler: @escaping @Sendable (String, [String], [String: String]?, String?, String?) -> ProcessResult) {
        self.handler = handler
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
        executedCommands.append(command)
        executedEnvironments.append(environment)
        executedExecutablePaths.append(executablePath)
        executedArguments.append(arguments)
        capturedTimeout = timeout
        return handler(command, arguments, environment, stdoutPath, stderrPath)
    }
}
