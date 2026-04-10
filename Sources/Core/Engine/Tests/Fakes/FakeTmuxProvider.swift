import Foundation
import Models

/// A fake `TmuxProviding` implementation for Engine tests.
///
/// Simulates a tmux session lifecycle: `sessionExists` returns true for
/// `existsCheckCount` calls, then returns false, simulating the session
/// exiting. This allows tests to verify the polling loop in
/// `InteractiveHandler.handleSession` without real tmux.
final class FakeTmuxProvider: TmuxProviding, @unchecked Sendable {
    /// Number of times `sessionExists` will return true before returning false.
    /// Set to 0 to simulate a session that has already exited.
    var existsCheckCount: Int = 2

    /// The output that `captureOutput` returns.
    var capturedOutput: String = ""

    /// When set, `captureOutput` throws this error (simulates session already gone).
    var captureError: (any Error)?

    /// When set, `sessionExists` throws this error.
    var sessionExistsError: (any Error)?

    /// Records how many times `sessionExists` was called.
    private(set) var sessionExistsCallCount: Int = 0

    /// Records how many times `captureOutput` was called.
    private(set) var captureOutputCallCount: Int = 0

    /// Records sessions that were destroyed via `destroySession`.
    private(set) var destroyedSessions: [String] = []

    func createSession(name: String, command: String, workingDirectory: String?) async throws {
        // No-op for Engine tests; the provider's executeInteractive handles creation.
    }

    func destroySession(name: String) async throws {
        destroyedSessions.append(name)
    }

    func captureOutput(name: String) async throws -> String {
        captureOutputCallCount += 1
        if let captureError {
            throw captureError
        }
        return capturedOutput
    }

    func sessionExists(name: String) async throws -> Bool {
        if let sessionExistsError {
            throw sessionExistsError
        }
        sessionExistsCallCount += 1
        if sessionExistsCallCount <= existsCheckCount {
            return true
        }
        return false
    }

    func isAvailable() async -> Bool {
        true
    }
}
