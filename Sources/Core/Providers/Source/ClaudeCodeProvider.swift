import Foundation
import Logging
import Models

// MARK: - ClaudeCodeProvider

/// Agent provider that wraps the Claude Code CLI (`claude -p ...`).
/// Non-interactive execution parses JSON output; interactive mode
/// delegates to a tmux session.
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

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil) async throws -> TaskOutput {
        let stdoutPath = NSTemporaryDirectory()
            + "orc-claude-stdout-\(UUID().uuidString).json"
        let stderrPath = NSTemporaryDirectory()
            + "orc-claude-stderr-\(UUID().uuidString).txt"

        // Temp files are intentionally NOT deleted here. The engine is
        // responsible for persisting log paths and cleaning up afterward,
        // so that stderr content remains available for log persistence.

        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let command = "\(claudePath) -p '\(escapedPrompt)' --output-format json"

        let result = try await processRunner.run(
            command: command,
            arguments: [],
            workingDirectory: context.workspacePath,
            environment: nil,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath
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
            workingDirectory: context.workspacePath
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
