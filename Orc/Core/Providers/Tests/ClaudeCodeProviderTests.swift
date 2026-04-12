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

@Suite("ClaudeCodeProvider")
struct ClaudeCodeProviderTests {
    let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/orc-test")

    @Test("Uses direct execution with discrete arguments to prevent shell injection")
    func directExecutionWithDiscreteArguments() async throws {
        let runner = FakeProcessRunner { _, _, stdoutPath, _ in
            // Write valid JSON to stdout so parsing succeeds.
            let json = """
                [{"type":"result","result":"test output"}]
                """
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: json.data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        let provider = ClaudeCodeProvider(
            claudePath: "/usr/local/bin/claude",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        _ = try await provider.execute(prompt: "Hello world", context: context)

        // Verify direct execution path is used (no shell wrapping).
        #expect(runner.capturedExecutablePath == "/usr/local/bin/claude")
        // Verify arguments are passed as discrete values, not interpolated
        // into a shell string. This prevents shell-string injection.
        #expect(runner.capturedArguments == ["-p", "Hello world", "--output-format", "json", "--permission-mode", "acceptEdits"])
    }

    @Test("Parses valid JSON array with result element")
    func validJSONParsing() async throws {
        let json = """
            [{"type":"assistant","message":"thinking..."},{"type":"result","result":"The answer is 42"}]
            """
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: json)

        let provider = ClaudeCodeProvider(
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        let output = try await provider.execute(prompt: "question", context: context)
        #expect(output.output == "The answer is 42")
        #expect(output.exitStatus == 0)
    }

    @Test("Parses single-element JSON array")
    func singleElementJSONArray() async throws {
        let json = """
            [{"type":"result","result":"single result"}]
            """
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: json)

        let provider = ClaudeCodeProvider(
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        let output = try await provider.execute(prompt: "test", context: context)
        #expect(output.output == "single result")
    }

    @Test("Throws outputParseFailure for malformed JSON")
    func malformedJSON() async throws {
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: "not json at all {{{")

        let provider = ClaudeCodeProvider(
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        await #expect(throws: ProviderError.self) {
            _ = try await provider.execute(prompt: "test", context: context)
        }
    }

    @Test("Throws outputParseFailure for empty response")
    func emptyResponse() async throws {
        let runner = FakeProcessRunner(exitCode: 0, stdoutContent: "")

        let provider = ClaudeCodeProvider(
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        await #expect(throws: ProviderError.self) {
            _ = try await provider.execute(prompt: "test", context: context)
        }
    }

    @Test("Throws processFailure for non-zero exit code")
    func nonZeroExitCode() async throws {
        let runner = FakeProcessRunner(exitCode: 1, stderrContent: "claude error")

        let provider = ClaudeCodeProvider(
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        await #expect(throws: ProviderError.self) {
            _ = try await provider.execute(prompt: "test", context: context)
        }
    }

    @Test("Passes shell metacharacters verbatim via direct execution (no injection)")
    func shellMetacharactersAreInert() async throws {
        let runner = FakeProcessRunner { _, _, stdoutPath, _ in
            let json = """
                [{"type":"result","result":"ok"}]
                """
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: json.data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        let provider = ClaudeCodeProvider(
            claudePath: "/usr/local/bin/claude",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        // A prompt containing shell metacharacters that would be dangerous
        // if interpreted by a shell (single quotes, semicolons, pipes, $()).
        let dangerousPrompt = "it's dangerous; rm -rf / | $(echo pwned)"
        _ = try await provider.execute(prompt: dangerousPrompt, context: context)

        // With direct execution the prompt is passed as a discrete argument,
        // so no escaping is needed — the raw string reaches the binary verbatim.
        #expect(runner.capturedExecutablePath == "/usr/local/bin/claude")
        #expect(runner.capturedArguments == ["-p", dangerousPrompt, "--output-format", "json", "--permission-mode", "acceptEdits"])
    }

    @Test("Defaults to acceptEdits when no permission mode specified")
    func defaultPermissionMode() async throws {
        let runner = FakeProcessRunner { _, _, stdoutPath, _ in
            let json = """
                [{"type":"result","result":"ok"}]
                """
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: json.data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        let provider = ClaudeCodeProvider(
            claudePath: "/usr/local/bin/claude",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        _ = try await provider.execute(prompt: "test", context: context)

        #expect(runner.capturedArguments?.contains("acceptEdits") == true)
    }

    @Test("Uses explicit permission mode when provided")
    func explicitPermissionMode() async throws {
        let runner = FakeProcessRunner { _, _, stdoutPath, _ in
            let json = """
                [{"type":"result","result":"ok"}]
                """
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: json.data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        let provider = ClaudeCodeProvider(
            claudePath: "/usr/local/bin/claude",
            processRunner: runner,
            tmuxProvider: FakeTmuxProvider()
        )

        _ = try await provider.execute(prompt: "test", context: context, permissionMode: .full)

        #expect(runner.capturedArguments == ["-p", "test", "--output-format", "json", "--permission-mode", "full"])
    }

    @Test("Interactive mode creates tmux session")
    func interactiveMode() async throws {
        let tmux = FakeTmuxProvider()
        let runner = FakeProcessRunner(exitCode: 0)

        let provider = ClaudeCodeProvider(
            claudePath: "/usr/local/bin/claude",
            processRunner: runner,
            tmuxProvider: tmux
        )

        let output = try await provider.executeInteractive(
            prompt: "interactive prompt",
            context: context,
            sessionName: "test-session"
        )

        #expect(output.output == "")
        #expect(output.exitStatus == 0)
        #expect(tmux.createdSessions.count == 1)
        #expect(tmux.createdSessions[0].name == "test-session")
        #expect(tmux.createdSessions[0].command == "/usr/local/bin/claude")
    }
}
