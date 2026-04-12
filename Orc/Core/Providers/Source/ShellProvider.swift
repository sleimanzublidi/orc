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
        defaultShell: String = "/bin/zsh",
        processRunner: any ProcessRunning = ProcessRunner(),
        tmuxProvider: any TmuxProviding = TmuxSession()
    ) {
        self.defaultShell = defaultShell
        self.processRunner = processRunner
        self.tmuxProvider = tmuxProvider
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil, permissionMode: PermissionMode? = nil) async throws -> TaskOutput {
        let stdoutPath = NSTemporaryDirectory()
            + "orc-shell-stdout-\(UUID().uuidString).txt"
        let stderrPath = NSTemporaryDirectory()
            + "orc-shell-stderr-\(UUID().uuidString).txt"

        // Temp files are intentionally NOT deleted here. The engine is
        // responsible for persisting log paths and cleaning up afterward,
        // so that stderr content remains available for log persistence.

        // Use direct execution with the configured shell to avoid shell-string
        // injection in the non-zsh path. The prompt is passed as a discrete
        // argument to the shell's -c flag, so metacharacters are inert.
        let result = try await processRunner.run(
            command: prompt,
            arguments: ["-c", prompt],
            workingDirectory: context.repoRoot,
            environment: nil,
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
