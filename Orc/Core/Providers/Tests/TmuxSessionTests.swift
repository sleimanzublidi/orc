import Foundation
import Models
import Testing

@testable import Providers

/// Tests for TmuxSession — verifies that each tmux operation delegates to the
/// ProcessRunning implementation with the correct command/arguments and interprets
/// exit codes correctly, without requiring a real tmux installation.
///
/// After migrating TmuxSession to direct execution, the `command` parameter is
/// just the executable name (e.g., "tmux") and the actual subcommands/flags are
/// passed via the `arguments` array. Assertions verify `capturedArguments` and
/// `capturedExecutablePath` on FakeProcessRunner instead of parsing a flat
/// command string.
@Suite("TmuxSession")
struct TmuxSessionTests {

    // MARK: - createSession

    @Test("createSession calls tmux new-session with correct arguments")
    func createSessionCommand() async throws {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        try await tmux.createSession(name: "test-session", command: "echo hello", workingDirectory: nil)

        // Direct execution: command is "tmux", arguments carry the subcommand and flags.
        let args = runner.capturedArguments ?? []
        #expect(args.contains("new-session"))
        #expect(args.contains("-d"))
        #expect(args.contains("-s"))
        #expect(args.contains("test-session"))
        #expect(args.contains("echo hello"))
        #expect(runner.capturedExecutablePath != nil)
    }

    @Test("createSession includes working directory when provided")
    func createSessionWithWorkingDirectory() async throws {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        try await tmux.createSession(name: "wd-session", command: "ls", workingDirectory: "/tmp/work")

        let args = runner.capturedArguments ?? []
        #expect(args.contains("-c"))
        #expect(args.contains("/tmp/work"))
    }

    @Test("createSession throws on non-zero exit code")
    func createSessionFailure() async throws {
        let runner = FakeProcessRunner(exitCode: 1)

        let tmux = TmuxSession(processRunner: runner)

        await #expect(throws: ProviderError.self) {
            try await tmux.createSession(name: "fail-session", command: "bad", workingDirectory: nil)
        }
    }

    // MARK: - destroySession

    @Test("destroySession calls tmux kill-session with correct session name")
    func destroySessionCommand() async throws {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        try await tmux.destroySession(name: "kill-me")

        let args = runner.capturedArguments ?? []
        #expect(args.contains("kill-session"))
        #expect(args.contains("-t"))
        #expect(args.contains("kill-me"))
        #expect(runner.capturedExecutablePath != nil)
    }

    @Test("destroySession throws on non-zero exit code")
    func destroySessionFailure() async throws {
        let runner = FakeProcessRunner(exitCode: 1)

        let tmux = TmuxSession(processRunner: runner)

        await #expect(throws: ProviderError.self) {
            try await tmux.destroySession(name: "no-such-session")
        }
    }

    // MARK: - captureOutput

    @Test("captureOutput calls tmux capture-pane and returns captured text")
    func captureOutputCommand() async throws {
        let runner = FakeProcessRunner { _, _, stdoutPath, _ in
            // Write captured content to the stdout file so TmuxSession can read it back.
            if let stdoutPath {
                FileManager.default.createFile(
                    atPath: stdoutPath,
                    contents: "captured pane content".data(using: .utf8)
                )
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: "/dev/null"
            )
        }

        let tmux = TmuxSession(processRunner: runner)
        let output = try await tmux.captureOutput(name: "cap-session")

        #expect(output == "captured pane content")
        // Verify the arguments contain the expected capture-pane subcommand.
        let args = runner.capturedArguments ?? []
        #expect(args.contains("capture-pane"))
        #expect(args.contains("-t"))
        #expect(args.contains("cap-session"))
    }

    @Test("captureOutput throws on non-zero exit code")
    func captureOutputFailure() async throws {
        let runner = FakeProcessRunner(exitCode: 1)

        let tmux = TmuxSession(processRunner: runner)

        await #expect(throws: ProviderError.self) {
            try await tmux.captureOutput(name: "no-session")
        }
    }

    // MARK: - sessionExists

    @Test("sessionExists returns true when tmux has-session exits 0")
    func sessionExistsTrue() async throws {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        let exists = try await tmux.sessionExists(name: "active-session")

        #expect(exists == true)
    }

    @Test("sessionExists returns false when tmux has-session exits non-zero")
    func sessionExistsFalse() async throws {
        let runner = FakeProcessRunner(exitCode: 1)

        let tmux = TmuxSession(processRunner: runner)
        let exists = try await tmux.sessionExists(name: "gone-session")

        #expect(exists == false)
    }

    @Test("sessionExists calls tmux has-session with correct session name")
    func sessionExistsCommand() async throws {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        _ = try await tmux.sessionExists(name: "check-session")

        let args = runner.capturedArguments ?? []
        #expect(args.contains("has-session"))
        #expect(args.contains("-t"))
        #expect(args.contains("check-session"))
        #expect(runner.capturedExecutablePath != nil)
    }

    // MARK: - isAvailable

    @Test("isAvailable returns true when 'which tmux' exits 0")
    func isAvailableTrue() async {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        let available = await tmux.isAvailable()

        #expect(available == true)
    }

    @Test("isAvailable returns false when 'which tmux' exits non-zero")
    func isAvailableFalse() async {
        let runner = FakeProcessRunner(exitCode: 1)

        let tmux = TmuxSession(processRunner: runner)
        let available = await tmux.isAvailable()

        #expect(available == false)
    }

    @Test("isAvailable checks for tmux binary via arguments")
    func isAvailableCommand() async {
        let runner = FakeProcessRunner(exitCode: 0)

        let tmux = TmuxSession(processRunner: runner)
        _ = await tmux.isAvailable()

        // Direct execution: command is "which", arguments contain "tmux".
        let args = runner.capturedArguments ?? []
        #expect(args.contains("tmux"))
        #expect(runner.capturedExecutablePath != nil)
    }
}
