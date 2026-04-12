import Foundation
import Logging
import Models

// MARK: - ShellProvider

/// Agent provider that runs shell commands directly. The "prompt" is treated
/// as a shell command (from the node's `command` field).
struct ShellProvider: AgentProviding, Sendable {
    let name = "shell"

    private let processRunner: any ProcessRunning
    private let tmuxProvider: any TmuxProviding
    private let defaultShell: String
    private let logger = Logger(label: "orc.providers.shell")

    init(
        defaultShell: String = Platform.defaultShell,
        processRunner: any ProcessRunning = ProcessRunner(),
        tmuxProvider: any TmuxProviding = TmuxSession()
    ) {
        self.defaultShell = defaultShell
        self.processRunner = processRunner
        self.tmuxProvider = tmuxProvider
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil, parameters: [String: String] = [:]) async throws -> TaskOutput {
        let stdoutPath = NSTemporaryDirectory()
            + "orc-shell-stdout-\(UUID().uuidString).txt"
        let stderrPath = NSTemporaryDirectory()
            + "orc-shell-stderr-\(UUID().uuidString).txt"

        // Temp files are intentionally NOT deleted here. The engine is
        // responsible for persisting log paths and cleaning up afterward,
        // so that stderr content remains available for log persistence.

        let environment = context.environment.isEmpty ? nil : context.environment

        // Use direct execution with the configured shell to avoid shell-string
        // injection in the non-zsh path. The prompt is passed as a discrete
        // argument to the shell's -c flag, so metacharacters are inert.
        let result = try await processRunner.run(
            command: prompt,
            arguments: ["-c", prompt],
            workingDirectory: context.repoRoot,
            environment: environment,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            executablePath: defaultShell
        )

        // Read stdout BEFORE checking exit code so diagnostic output is
        // not lost when the process fails (H13).
        let output = FileReader.readContents(at: stdoutPath)

        guard result.exitCode == 0 else {
            let stderr = FileReader.readContents(at: stderrPath)
            throw ProviderError.processFailure(
                command: prompt,
                exitCode: result.exitCode,
                stderr: stderr
            )
        }

        return TaskOutput(output: output, exitStatus: Int(result.exitCode))
    }

    func executeStreaming(
        prompt: String,
        context: TaskContext,
        timeout: Int? = nil,
        parameters: [String: String] = [:]
    ) -> AsyncThrowingStream<AgentStreamEvent, any Error> {
        let stdoutPath = NSTemporaryDirectory()
            + "orc-shell-stdout-\(UUID().uuidString).txt"
        let stderrPath = NSTemporaryDirectory()
            + "orc-shell-stderr-\(UUID().uuidString).txt"

        let environment = context.environment.isEmpty ? nil : context.environment

        let processStream = processRunner.runStreaming(
            command: prompt,
            arguments: ["-c", prompt],
            workingDirectory: context.repoRoot,
            environment: environment,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            executablePath: defaultShell
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var exitCode: Int32 = 0
                    for try await event in processStream {
                        switch event {
                        case .stdout(let data):
                            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                                continuation.yield(.output(text, .stdout))
                            }
                        case .stderr(let data):
                            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                                continuation.yield(.output(text, .stderr))
                            }
                        case .completed(let result):
                            exitCode = result.exitCode
                            let output = FileReader.readContents(at: result.stdoutPath)
                            guard result.exitCode == 0 else {
                                let stderr = FileReader.readContents(at: result.stderrPath)
                                continuation.finish(throwing: ProviderError.processFailure(
                                    command: prompt,
                                    exitCode: result.exitCode,
                                    stderr: stderr
                                ))
                                return
                            }
                            continuation.yield(.completed(TaskOutput(
                                output: output,
                                exitStatus: Int(exitCode)
                            )))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func executeInteractive(
        prompt: String,
        context: TaskContext,
        sessionName: String,
        timeout: Int? = nil
    ) async throws -> TaskOutput {
        try await tmuxProvider.createSession(
            name: sessionName,
            command: prompt,
            workingDirectory: context.repoRoot
        )

        return TaskOutput(output: "", exitStatus: 0)
    }

}
