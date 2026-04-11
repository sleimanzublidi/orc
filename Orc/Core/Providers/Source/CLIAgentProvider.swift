import Foundation
import Logging
import Models

// MARK: - CLIAgentProvider

/// Generic agent provider that wraps any CLI command. The `commandTemplate`
/// may contain `{{prompt}}` which is substituted with the actual prompt at
/// execution time. For interactive mode, a separate `interactiveCommand`
/// is launched inside a tmux session.
struct CLIAgentProvider: AgentProviding, Sendable {
    let name: String

    private let commandTemplate: String
    private let interactiveCommand: String?
    private let processRunner: any ProcessRunning
    private let tmuxProvider: any TmuxProviding
    private let logger = Logger(label: "orc.providers.cli-agent")

    init(
        name: String,
        commandTemplate: String,
        interactiveCommand: String? = nil,
        processRunner: any ProcessRunning = ProcessRunner(),
        tmuxProvider: any TmuxProviding = TmuxSession()
    ) {
        self.name = name
        self.commandTemplate = commandTemplate
        self.interactiveCommand = interactiveCommand
        self.processRunner = processRunner
        self.tmuxProvider = tmuxProvider
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil) async throws -> TaskOutput {
        // NOTE: CLIAgentProvider intentionally uses shell-string construction (not
        // direct execution) because the command template is user-defined and may
        // require shell features (pipes, redirects, variable expansion, etc.).
        // The prompt is escaped and single-quoted to prevent injection, which is
        // the correct mitigation for this use case. Other providers (ClaudeCodeProvider,
        // ShellProvider, TmuxSession) use direct execution where the executable and
        // argument structure are known at compile time.
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let command = commandTemplate.replacingOccurrences(of: "{{prompt}}", with: "'\(escapedPrompt)'")

        let stdoutPath = NSTemporaryDirectory()
            + "orc-cli-agent-stdout-\(UUID().uuidString).txt"
        let stderrPath = NSTemporaryDirectory()
            + "orc-cli-agent-stderr-\(UUID().uuidString).txt"

        // Temp files are intentionally NOT deleted here. The engine is
        // responsible for persisting log paths and cleaning up afterward,
        // so that stderr content remains available for log persistence.

        let result = try await processRunner.run(
            command: command,
            arguments: [],
            workingDirectory: context.repoRoot,
            environment: nil,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath
        )

        let output = FileReader.readContents(at: stdoutPath)

        guard result.exitCode == 0 else {
            let stderr = FileReader.readContents(at: stderrPath)
            throw ProviderError.processFailure(
                command: command,
                exitCode: result.exitCode,
                stderr: stderr
            )
        }

        return TaskOutput(output: output, exitStatus: Int(result.exitCode))
    }

    func executeInteractive(
        prompt: String,
        context: TaskContext,
        sessionName: String,
        timeout: Int? = nil
    ) async throws -> TaskOutput {
        guard let interactiveCommand else {
            throw ProviderError.tmuxFailure(
                session: sessionName,
                detail: "No interactive command configured for provider '\(name)'"
            )
        }

        try await tmuxProvider.createSession(
            name: sessionName,
            command: interactiveCommand,
            workingDirectory: context.repoRoot
        )

        return TaskOutput(output: "", exitStatus: 0)
    }

}
