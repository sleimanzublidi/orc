import Foundation
import Models
import Providers

/// A fake `TmuxProviding` implementation for tests.
/// Records calls and returns pre-configured values without
/// touching real tmux sessions.
final class FakeTmuxProvider: TmuxProviding, @unchecked Sendable {
    var createdSessions: [(name: String, command: String, workingDirectory: String?)] = []
    var destroyedSessions: [String] = []
    var capturedOutput: String = ""
    var available: Bool = true

    /// Tracks which sessions are considered "alive". `sessionExists` returns
    /// true while a name is in this set. Callers can remove entries to
    /// simulate a session exiting.
    var activeSessions: Set<String> = []

    /// When set, `createSession` throws this error.
    var createError: (any Error)?
    /// When set, `destroySession` throws this error.
    var destroyError: (any Error)?
    /// When set, `captureOutput` throws this error.
    var captureError: (any Error)?

    func createSession(name: String, command: String, workingDirectory: String?) async throws {
        if let createError {
            throw createError
        }
        createdSessions.append((name: name, command: command, workingDirectory: workingDirectory))
    }

    func destroySession(name: String) async throws {
        if let destroyError {
            throw destroyError
        }
        destroyedSessions.append(name)
    }

    func captureOutput(name: String) async throws -> String {
        if let captureError {
            throw captureError
        }
        return capturedOutput
    }

    func sessionExists(name: String) async throws -> Bool {
        activeSessions.contains(name)
    }

    func isAvailable() async -> Bool {
        available
    }
}
