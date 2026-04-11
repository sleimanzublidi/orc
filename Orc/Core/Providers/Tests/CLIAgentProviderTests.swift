import Foundation
import Models
import Testing

@testable import Providers

/// Thread-safe box for capturing values inside `@Sendable` closures.
private final class CaptureBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    var value: T? {
        lock.withLock { _value }
    }

    func set(_ newValue: T) {
        lock.withLock { _value = newValue }
    }
}

@Suite("CLIAgentProvider")
struct CLIAgentProviderTests {
    let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/orc-test")

    @Test("Substitutes {{prompt}} in command template")
    func promptSubstitution() async throws {
        let captured = CaptureBox<String>()

        let runner = FakeProcessRunner { command, _, stdoutPath, _ in
            captured.set(command)
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: "result".data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        // Template does NOT wrap {{prompt}} in quotes — the provider wraps it
        // automatically to prevent command injection (H1 fix).
        let provider = CLIAgentProvider(
            name: "custom-agent",
            commandTemplate: "my-tool --query {{prompt}} --json",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        _ = try await provider.execute(prompt: "find bugs", context: context)

        #expect(captured.value == "my-tool --query 'find bugs' --json")
    }

    @Test("Returns stdout content as output")
    func returnsStdout() async throws {
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: "agent response")

        let provider = CLIAgentProvider(
            name: "test-agent",
            commandTemplate: "agent {{prompt}}",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        let output = try await provider.execute(prompt: "do something", context: context)
        #expect(output.output == "agent response")
    }

    @Test("Throws processFailure on non-zero exit code")
    func nonZeroExitCode() async throws {
        let runner = FakeProcessRunner(exitCode: 1, stderrContent: "agent error")

        let provider = CLIAgentProvider(
            name: "test-agent",
            commandTemplate: "agent {{prompt}}",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        do {
            _ = try await provider.execute(prompt: "fail", context: context)
            Issue.record("Expected ProviderError.processFailure to be thrown")
        } catch let error as ProviderError {
            if case .processFailure(_, let exitCode, _) = error {
                #expect(exitCode == 1)
            } else {
                Issue.record("Expected processFailure, got \(error)")
            }
        }
    }

    @Test("Interactive with configured interactiveCommand creates tmux session")
    func interactiveWithCommand() async throws {
        let tmux = FakeTmuxProvider()

        let provider = CLIAgentProvider(
            name: "test-agent",
            commandTemplate: "agent {{prompt}}",
            interactiveCommand: "agent --interactive",
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: tmux
        )

        let output = try await provider.executeInteractive(
            prompt: "interact",
            context: context,
            sessionName: "agent-session"
        )

        #expect(output.output == "")
        #expect(tmux.createdSessions.count == 1)
        #expect(tmux.createdSessions[0].name == "agent-session")
        #expect(tmux.createdSessions[0].command == "agent --interactive")
    }

    @Test("Interactive without interactiveCommand throws error")
    func interactiveWithoutCommand() async throws {
        let provider = CLIAgentProvider(
            name: "test-agent",
            commandTemplate: "agent {{prompt}}",
            interactiveCommand: nil,
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )

        await #expect(throws: ProviderError.self) {
            _ = try await provider.executeInteractive(
                prompt: "interact",
                context: context,
                sessionName: "agent-session"
            )
        }
    }

    @Test("Shell-escapes single quotes in prompt to prevent command injection")
    func shellEscapesSingleQuotes() async throws {
        let captured = CaptureBox<String>()

        let runner = FakeProcessRunner { command, _, stdoutPath, _ in
            captured.set(command)
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: "ok".data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        // Template references {{prompt}} without quotes. The provider wraps the
        // escaped prompt in single quotes automatically.
        let provider = CLIAgentProvider(
            name: "test-agent",
            commandTemplate: "agent {{prompt}}",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        // A prompt containing a single quote and shell metacharacters.
        _ = try await provider.execute(prompt: "it's dangerous; rm -rf /", context: context)

        // The provider wraps in single quotes and escapes internal quotes:
        // agent 'it'\''s dangerous; rm -rf /'
        #expect(captured.value == "agent 'it'\\''s dangerous; rm -rf /'")
    }

    @Test("Provider name matches configured name")
    func providerName() {
        let provider = CLIAgentProvider(
            name: "my-custom-agent",
            commandTemplate: "tool {{prompt}}",
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )
        #expect(provider.name == "my-custom-agent")
    }
}
