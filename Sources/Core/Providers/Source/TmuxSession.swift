import Foundation
import Logging
import Models

// MARK: - TmuxSession

/// Manages tmux sessions for interactive agent nodes by delegating
/// subprocess execution to a `ProcessRunning` implementation.
struct TmuxSession: TmuxProviding, Sendable {
    private let processRunner: any ProcessRunning
    private let logger = Logger(label: "orc.providers.tmux")

    init(processRunner: any ProcessRunning = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func createSession(
        name: String,
        command: String,
        workingDirectory: String?
    ) async throws {
        var args = "tmux new-session -d -s \(shellEscape(name)) \(shellEscape(command))"
        if let workingDirectory {
            args = "tmux new-session -d -s \(shellEscape(name)) -c \(shellEscape(workingDirectory)) \(shellEscape(command))"
        }

        let result = try await processRunner.run(
            command: args,
            arguments: [],
            workingDirectory: workingDirectory,
            environment: nil,
            timeout: 30,
            stdoutPath: nil,
            stderrPath: nil
        )

        guard result.exitCode == 0 else {
            throw ProviderError.tmuxFailure(
                session: name,
                detail: "Failed to create session (exit code \(result.exitCode))"
            )
        }
    }

    func destroySession(name: String) async throws {
        let result = try await processRunner.run(
            command: "tmux kill-session -t \(shellEscape(name))",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: 10,
            stdoutPath: nil,
            stderrPath: nil
        )

        guard result.exitCode == 0 else {
            throw ProviderError.tmuxFailure(
                session: name,
                detail: "Failed to destroy session (exit code \(result.exitCode))"
            )
        }
    }

    func captureOutput(name: String) async throws -> String {
        let tmpPath = NSTemporaryDirectory() + "orc-tmux-capture-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let result = try await processRunner.run(
            command: "tmux capture-pane -t \(shellEscape(name)) -p",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: 10,
            stdoutPath: tmpPath,
            stderrPath: nil
        )

        guard result.exitCode == 0 else {
            throw ProviderError.tmuxFailure(
                session: name,
                detail: "Failed to capture pane output (exit code \(result.exitCode))"
            )
        }

        guard let data = FileManager.default.contents(atPath: tmpPath),
              let output = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sessionExists(name: String) async throws -> Bool {
        let result = try await processRunner.run(
            command: "tmux has-session -t \(shellEscape(name))",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: 10,
            stdoutPath: nil,
            stderrPath: nil
        )
        return result.exitCode == 0
    }

    func isAvailable() async -> Bool {
        do {
            let result = try await processRunner.run(
                command: "which tmux",
                arguments: [],
                workingDirectory: nil,
                environment: nil,
                timeout: 5,
                stdoutPath: nil,
                stderrPath: nil
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Wraps a string in single quotes for safe shell interpolation.
    private func shellEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
