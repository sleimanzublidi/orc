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

    private static let tmuxPath = "/usr/bin/tmux"

    func createSession(
        name: String,
        command: String,
        workingDirectory: String?
    ) async throws {
        var args = ["new-session", "-d", "-s", name]
        if let workingDirectory {
            args += ["-c", workingDirectory]
        }
        args.append(command)

        let result = try await processRunner.run(
            command: "tmux",
            arguments: args,
            workingDirectory: workingDirectory,
            environment: nil,
            timeout: 30,
            stdoutPath: nil,
            stderrPath: nil,
            executablePath: Self.tmuxPath
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
            command: "tmux",
            arguments: ["kill-session", "-t", name],
            workingDirectory: nil,
            environment: nil,
            timeout: 10,
            stdoutPath: nil,
            stderrPath: nil,
            executablePath: Self.tmuxPath
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
            command: "tmux",
            arguments: ["capture-pane", "-t", name, "-p"],
            workingDirectory: nil,
            environment: nil,
            timeout: 10,
            stdoutPath: tmpPath,
            stderrPath: nil,
            executablePath: Self.tmuxPath
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
            command: "tmux",
            arguments: ["has-session", "-t", name],
            workingDirectory: nil,
            environment: nil,
            timeout: 10,
            stdoutPath: nil,
            stderrPath: nil,
            executablePath: Self.tmuxPath
        )
        return result.exitCode == 0
    }

    func isAvailable() async -> Bool {
        do {
            let result = try await processRunner.run(
                command: "which",
                arguments: ["tmux"],
                workingDirectory: nil,
                environment: nil,
                timeout: 5,
                stdoutPath: nil,
                stderrPath: nil,
                executablePath: "/usr/bin/which"
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }
}
