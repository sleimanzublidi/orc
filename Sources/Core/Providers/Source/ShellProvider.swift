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

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil) async throws -> TaskOutput {
        let stdoutPath = NSTemporaryDirectory()
            + "orc-shell-stdout-\(UUID().uuidString).txt"
        let stderrPath = NSTemporaryDirectory()
            + "orc-shell-stderr-\(UUID().uuidString).txt"

        // Temp files are intentionally NOT deleted here. The engine is
        // responsible for persisting log paths and cleaning up afterward,
        // so that stderr content remains available for log persistence.

        // Use the configured shell to run the command. ProcessRunner executes
        // via /bin/zsh by default, so we wrap in the configured shell to
        // honor the user's default_shell setting.
        let command: String
        if defaultShell == "/bin/zsh" {
            command = prompt
        } else {
            let escaped = prompt.replacingOccurrences(of: "'", with: "'\\''")
            command = "\(defaultShell) -c '\(escaped)'"
        }

        let result = try await processRunner.run(
            command: command,
            arguments: [],
            workingDirectory: context.workspacePath,
            environment: nil,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath
        )

        // Read stdout BEFORE checking exit code so diagnostic output is
        // not lost when the process fails (H13).
        let output = readFileContents(at: stdoutPath)

        guard result.exitCode == 0 else {
            let stderr = readFileContents(at: stderrPath)
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
            workingDirectory: context.workspacePath
        )

        return TaskOutput(output: "", exitStatus: 0)
    }

    private func readFileContents(at path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
