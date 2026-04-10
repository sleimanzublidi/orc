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
    let context = TaskContext(workspacePath: "/tmp/orc-test")

    @Test("Passes correct CLI arguments to process runner")
    func correctCLIArguments() async throws {
        let captured = CaptureBox<String>()

        let runner = FakeProcessRunner { command, _, stdoutPath, _ in
            captured.set(command)
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

        let capturedCommand = captured.value
        #expect(capturedCommand?.contains("claude") == true)
        #expect(capturedCommand?.contains("-p") == true)
        #expect(capturedCommand?.contains("--output-format json") == true)
        #expect(capturedCommand?.contains("Hello world") == true)
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

    @Test("Shell-escapes single quotes in prompt to prevent command injection")
    func shellEscapesSingleQuotes() async throws {
        let captured = CaptureBox<String>()

        let runner = FakeProcessRunner { command, _, stdoutPath, _ in
            captured.set(command)
            // Write valid JSON so parsing succeeds.
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

        // A prompt containing a single quote.
        _ = try await provider.execute(prompt: "it's a test", context: context)

        // The provider escapes ' as '\'' inside the single-quoted prompt:
        // /usr/local/bin/claude -p 'it'\''s a test' --output-format json
        let capturedCommand = captured.value
        #expect(capturedCommand == "/usr/local/bin/claude -p 'it'\\''s a test' --output-format json")
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
