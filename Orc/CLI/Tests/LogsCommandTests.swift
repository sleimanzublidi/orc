import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("LogsCommand")
struct LogsCommandTests {

    @Test("handles empty logs")
    func handlesEmptyLogs() async throws {
        let mock = MockEngine()
        mock.getLogsHandler = { _, _, _, _ in [] }

        let cmd = try LogsCommand.parseAsRoot(["abc"]) as! LogsCommand
        try await cmd.execute(engine: mock)
    }

    @Test("passes filter options to engine")
    func passesFilterOptions() async throws {
        let mock = MockEngine()
        var receivedRunID: String?
        var receivedNodeID: String?
        var receivedAttempt: Int?
        var receivedIteration: Int?

        mock.getLogsHandler = { runID, nodeID, attempt, iteration in
            receivedRunID = runID
            receivedNodeID = nodeID
            receivedAttempt = attempt
            receivedIteration = iteration
            return []
        }

        let cmd = try LogsCommand.parseAsRoot([
            "abc", "--node", "build", "--attempt", "2", "--iteration", "3",
        ]) as! LogsCommand
        try await cmd.execute(engine: mock)

        #expect(receivedRunID == "abc")
        #expect(receivedNodeID == "build")
        #expect(receivedAttempt == 2)
        #expect(receivedIteration == 3)
    }

    @Test("passes nil filters when no options specified")
    func passesNilFiltersWhenNoOptions() async throws {
        let mock = MockEngine()
        var receivedNodeID: String?
        var receivedAttempt: Int?
        var receivedIteration: Int?

        mock.getLogsHandler = { _, nodeID, attempt, iteration in
            receivedNodeID = nodeID
            receivedAttempt = attempt
            receivedIteration = iteration
            return []
        }

        let cmd = try LogsCommand.parseAsRoot(["abc"]) as! LogsCommand
        try await cmd.execute(engine: mock)

        #expect(receivedNodeID == nil)
        #expect(receivedAttempt == nil)
        #expect(receivedIteration == nil)
    }

    @Test("handles log entry with missing file")
    func handlesLogEntryWithMissingFile() async throws {
        let mock = MockEngine()
        mock.getLogsHandler = { _, _, _, _ in
            [
                TestFixtures.makeLogEntry(
                    nodeExecutionID: "exec1",
                    stream: .stdout,
                    filePath: "/nonexistent/path/log.txt"
                )
            ]
        }

        let cmd = try LogsCommand.parseAsRoot(["abc"]) as! LogsCommand
        // Should not throw -- prints "(log file not found: ...)" instead.
        try await cmd.execute(engine: mock)
    }

    @Test("handles log entry with existing file")
    func handlesLogEntryWithExistingFile() async throws {
        // Create a temporary log file with known content.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = tempDir.appendingPathComponent("test-stdout.log")
        try "Hello from test log\n".write(to: logFile, atomically: true, encoding: .utf8)

        let mock = MockEngine()
        mock.getLogsHandler = { _, _, _, _ in
            [
                TestFixtures.makeLogEntry(
                    nodeExecutionID: "exec1",
                    stream: .stdout,
                    filePath: logFile.path
                )
            ]
        }

        let cmd = try LogsCommand.parseAsRoot(["abc"]) as! LogsCommand
        // Should succeed and print the file content.
        try await cmd.execute(engine: mock)
    }

    @Test("handles multiple log entries")
    func handlesMultipleLogEntries() async throws {
        let mock = MockEngine()
        mock.getLogsHandler = { _, _, _, _ in
            [
                TestFixtures.makeLogEntry(
                    nodeExecutionID: "exec1",
                    stream: .stdout,
                    filePath: "/nonexistent/stdout.log"
                ),
                TestFixtures.makeLogEntry(
                    nodeExecutionID: "exec1",
                    stream: .stderr,
                    filePath: "/nonexistent/stderr.log"
                ),
            ]
        }

        let cmd = try LogsCommand.parseAsRoot(["abc"]) as! LogsCommand
        try await cmd.execute(engine: mock)
    }

    @Test("throws ExitCode.failure when engine throws")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.getLogsHandler = { _, _, _, _ in
            throw EngineError.runNotFound(id: "abc")
        }

        let cmd = try! LogsCommand.parseAsRoot(["abc"]) as! LogsCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
