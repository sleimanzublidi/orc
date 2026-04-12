import Foundation
import Logging
import Models

// MARK: - ClaudePermissionMode

/// Claude Code `--permission-mode` values. Provider-specific — not part of
/// the core model or protocol.
enum ClaudePermissionMode: String, Sendable {
    case defaultMode = "default"
    case acceptEdits
    case dontAsk
    case plan
    case auto
    case bypassPermissions
}

// MARK: - ClaudeCodeProvider

/// Agent provider that wraps the Claude Code CLI (`claude -p ...`).
/// Non-interactive execution parses JSON output; interactive mode
/// delegates to a tmux session.
///
/// Recognized parameters (via `parameters:` in YAML):
/// - `permission_mode`: Claude Code `--permission-mode` value (default: `acceptEdits`)
/// - `bare`: When `"true"`, passes `--bare` for minimal mode (requires API key in environment)
/// - `model`: Override the Claude model (e.g., `opus`, `sonnet`)
struct ClaudeCodeProvider: AgentProviding, Sendable {
    let name = "claude-code"

    private let processRunner: any ProcessRunning
    private let tmuxProvider: any TmuxProviding
    private let claudePath: String
    private let logger = Logger(label: "orc.providers.claude-code")

    init(
        claudePath: String = "/usr/local/bin/claude",
        processRunner: any ProcessRunning = ProcessRunner(),
        tmuxProvider: any TmuxProviding = TmuxSession()
    ) {
        self.claudePath = claudePath
        self.processRunner = processRunner
        self.tmuxProvider = tmuxProvider
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil, parameters: [String: String] = [:]) async throws -> TaskOutput {
        let stdoutPath = NSTemporaryDirectory()
            + "orc-claude-stdout-\(UUID().uuidString).json"
        let stderrPath = NSTemporaryDirectory()
            + "orc-claude-stderr-\(UUID().uuidString).txt"

        // Temp files are intentionally NOT deleted here. The engine is
        // responsible for persisting log paths and cleaning up afterward,
        // so that stderr content remains available for log persistence.

        let mode = ClaudePermissionMode(rawValue: parameters["permission_mode"] ?? "") ?? .acceptEdits
        let bare = parameters["bare"] == "true"
        let model = parameters["model"]

        // Use direct execution to avoid shell-string injection. The prompt
        // is passed as a discrete argument, so shell meta-characters in user
        // prompts (;, |, $(), etc.) are inert.
        var arguments = ["-p", prompt,
                         "--no-chrome",
                         "--output-format", "json",
                         "--permission-mode", mode.rawValue]
        if bare { arguments += ["--bare"] }
        if let model { arguments += ["--model", model] }

        // Pass context environment (includes .env values) to the child process.
        let environment = context.environment.isEmpty ? nil : context.environment

        let result = try await processRunner.run(
            command: claudePath,
            arguments: arguments,
            workingDirectory: context.repoRoot,
            environment: environment,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            executablePath: claudePath
        )

        guard result.exitCode == 0 else {
            let stderr = FileReader.readContents(at: stderrPath)
            throw ProviderError.processFailure(
                command: "claude -p",
                exitCode: result.exitCode,
                stderr: stderr
            )
        }

        let rawOutput = FileReader.readContents(at: stdoutPath)
        let text = try parseClaudeJSON(rawOutput)

        return TaskOutput(output: text, exitStatus: Int(result.exitCode))
    }

    func executeInteractive(
        prompt: String,
        context: TaskContext,
        sessionName: String,
        timeout: Int? = nil
    ) async throws -> TaskOutput {
        let command = "\(claudePath)"
        try await tmuxProvider.createSession(
            name: sessionName,
            command: command,
            workingDirectory: context.repoRoot
        )

        return TaskOutput(output: "", exitStatus: 0)
    }

    // MARK: - JSON Parsing

    /// Parses Claude Code's `--output-format json` response.
    /// Expected shape: a JSON array where the last element with `"type": "result"`
    /// contains the text content in its `"result"` field.
    private func parseClaudeJSON(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError.outputParseFailure(
                provider: name,
                detail: "Empty JSON response"
            )
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw ProviderError.outputParseFailure(
                provider: name,
                detail: "Could not convert response to UTF-8 data"
            )
        }

        // Try parsing as a JSON array of objects.
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            // Walk backwards to find the last "result" element.
            for element in array.reversed() {
                if let type = element["type"] as? String, type == "result",
                   let resultText = element["result"] as? String
                {
                    return resultText
                }
            }

            // If no "result" element found, try extracting any text content.
            if let first = array.first,
               let resultText = first["result"] as? String
            {
                return resultText
            }

            throw ProviderError.outputParseFailure(
                provider: name,
                detail: "No result element found in JSON array"
            )
        }

        // Try parsing as a single JSON object.
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let resultText = dict["result"] as? String {
                return resultText
            }
        }

        // Fallback: if it's not valid JSON, treat the raw output as plain text
        // since some claude versions may output plain text.
        throw ProviderError.outputParseFailure(
            provider: name,
            detail: "Malformed JSON response"
        )
    }

}
