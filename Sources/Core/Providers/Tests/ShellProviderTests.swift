import Foundation
import Models
import Testing

@testable import Providers

@Suite("ShellProvider")
struct ShellProviderTests {
    let context = TaskContext(workspacePath: "/tmp/orc-test")

    @Test("Captures stdout as output on success")
    func capturesStdout() async throws {
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: "command output here")

        let provider = ShellProvider(processRunner: runner, tmuxProvider: FakeTmuxProvider())
        let output = try await provider.execute(prompt: "ls -la", context: context)

        #expect(output.output == "command output here")
        #expect(output.exitStatus == 0)
    }

    @Test("Throws processFailure on non-zero exit code")
    func nonZeroExitCode() async throws {
        let runner = FakeProcessRunner(
            exitCode: 127,
            stderrContent: "command not found"
        )

        let provider = ShellProvider(processRunner: runner, tmuxProvider: FakeTmuxProvider())

        do {
            _ = try await provider.execute(prompt: "nonexistent-command", context: context)
            Issue.record("Expected ProviderError.processFailure to be thrown")
        } catch let error as ProviderError {
            if case .processFailure(let command, let exitCode, let stderr) = error {
                #expect(command == "nonexistent-command")
                #expect(exitCode == 127)
                #expect(stderr == "command not found")
            } else {
                Issue.record("Expected processFailure, got \(error)")
            }
        }
    }

    @Test("Stderr goes to file, not output")
    func stderrNotInOutput() async throws {
        let runner = FakeProcessRunner { _, _, stdoutPath, stderrPath in
            // Write to stdout
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: "stdout content".data(using: .utf8)
                )
            }
            // Write to stderr (should not appear in output)
            if let stderrPath {
                FileManager.default.createFile(
                    atPath: stderrPath,
                    contents: "stderr content".data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        }

        let provider = ShellProvider(processRunner: runner, tmuxProvider: FakeTmuxProvider())
        let output = try await provider.execute(prompt: "some command", context: context)

        // Only stdout should be in the output
        #expect(output.output == "stdout content")
        #expect(!output.output.contains("stderr"))
    }

    @Test("Interactive mode creates tmux session")
    func interactiveMode() async throws {
        let tmux = FakeTmuxProvider()
        let runner = FakeProcessRunner(exitCode: 0)

        let provider = ShellProvider(processRunner: runner, tmuxProvider: tmux)

        let output = try await provider.executeInteractive(
            prompt: "top",
            context: context,
            sessionName: "shell-session"
        )

        #expect(output.output == "")
        #expect(output.exitStatus == 0)
        #expect(tmux.createdSessions.count == 1)
        #expect(tmux.createdSessions[0].name == "shell-session")
        #expect(tmux.createdSessions[0].command == "top")
    }

    @Test("Timeout value is forwarded to process runner")
    func timeoutForwarding() async throws {
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: "ok")

        let provider = ShellProvider(processRunner: runner, tmuxProvider: FakeTmuxProvider())
        _ = try await provider.execute(prompt: "sleep 100", context: context, timeout: 42)

        #expect(runner.capturedTimeout == 42)
    }

    @Test("Nil timeout is forwarded as nil to process runner")
    func nilTimeoutForwarding() async throws {
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: "ok")

        let provider = ShellProvider(processRunner: runner, tmuxProvider: FakeTmuxProvider())
        _ = try await provider.execute(prompt: "echo hi", context: context)

        #expect(runner.capturedTimeout == nil)
    }

    @Test("Provider name is 'shell'")
    func providerName() {
        let provider = ShellProvider(
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )
        #expect(provider.name == "shell")
    }
}
