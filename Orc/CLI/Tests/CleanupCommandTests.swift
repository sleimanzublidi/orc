import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("CleanupCommand")
struct CleanupCommandTests {

    // MARK: - Single Run ID

    @Test("passes runID to engine.cleanupWorkspace")
    func passesRunID() async throws {
        let mock = MockEngine()
        var receivedID: String?
        mock.cleanupWorkspaceHandler = { id in receivedID = id }

        let cmd = try CleanupCommand.parseAsRoot(["run-cleanup-1"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedID == "run-cleanup-1")
    }

    @Test("throws ExitCode.failure when engine throws EngineError")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.cleanupWorkspaceHandler = { id in
            throw EngineError.workspaceNotFound(runID: id)
        }

        let cmd = try! CleanupCommand.parseAsRoot(["no-workspace"]) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    // MARK: - Bulk by Status

    @Test("'completed' positional calls cleanupRuns with status filter")
    func bulkByStatus() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?
        mock.cleanupRunsHandler = { _, status in
            receivedStatus = status
            return 2
        }

        let cmd = try CleanupCommand.parseAsRoot(["completed"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedStatus == .completed)
    }

    // MARK: - Bulk All

    @Test("'all' positional calls cleanupRuns with nil status")
    func bulkAll() async throws {
        let mock = MockEngine()
        var receivedDate: Date??  = .none
        var receivedStatus: RunStatus?? = .none
        mock.cleanupRunsHandler = { date, status in
            receivedDate = .some(date)
            receivedStatus = .some(status)
            return 5
        }

        let cmd = try CleanupCommand.parseAsRoot(["all"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate == .some(nil))
        #expect(receivedStatus == .some(nil))
    }

    // MARK: - Bulk by Date

    @Test("'<2026-04-15' positional calls cleanupRuns with cutoff date")
    func bulkByDate() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        mock.cleanupRunsHandler = { date, _ in
            receivedDate = date
            return 3
        }

        let cmd = try CleanupCommand.parseAsRoot(["<2026-04-15"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
        // Verify the date is April 15, 2026 UTC.
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: receivedDate!
        )
        #expect(components.year == 2026)
        #expect(components.month == 4)
        #expect(components.day == 15)
    }

    // MARK: - Named Options

    @Test("--older-than parses duration")
    func olderThanDuration() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        mock.cleanupRunsHandler = { date, _ in
            receivedDate = date
            return 1
        }

        let cmd = try CleanupCommand.parseAsRoot(["all", "--older-than", "30d"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        let expected = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        #expect(receivedDate != nil)
        #expect(abs(receivedDate!.timeIntervalSince(expected)) < 1.0)
    }

    @Test("--older-than accepts ISO date string")
    func olderThanISODate() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        mock.cleanupRunsHandler = { date, _ in
            receivedDate = date
            return 1
        }

        let cmd = try CleanupCommand.parseAsRoot(
            ["all", "--older-than", "2026-01-01"]
        ) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
    }

    @Test("--status parses valid status")
    func statusOption() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?
        mock.cleanupRunsHandler = { _, status in
            receivedStatus = status
            return 1
        }

        let cmd = try CleanupCommand.parseAsRoot(["--status", "failed"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedStatus == .failed)
    }

    @Test("--status 'all' maps to nil status filter")
    func statusAllOption() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?? = .none
        mock.cleanupRunsHandler = { _, status in
            receivedStatus = .some(status)
            return 1
        }

        let cmd = try CleanupCommand.parseAsRoot(["--status", "all"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedStatus == .some(nil))
    }

    // MARK: - Dry Run

    @Test("--dry-run shows list without cleaning")
    func dryRunSingleRun() async throws {
        let mock = MockEngine()
        var cleanupCalled = false
        mock.cleanupWorkspaceHandler = { _ in cleanupCalled = true }

        let cmd = try CleanupCommand.parseAsRoot(["my-run-id", "--dry-run"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(!cleanupCalled)
    }

    @Test("--dry-run with bulk filter shows list without cleaning")
    func dryRunBulk() async throws {
        let mock = MockEngine()
        var cleanupCalled = false
        mock.cleanupRunsHandler = { _, _ in
            cleanupCalled = true
            return 0
        }
        mock.listRunsHandler = { _, _ in
            [TestFixtures.makeRun(id: "run-1", status: .completed)]
        }

        let cmd = try CleanupCommand.parseAsRoot(["completed", "--dry-run"]) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(!cleanupCalled)
    }

    // MARK: - Error Cases

    @Test("throws ExitCode on invalid date filter")
    func invalidDateFilter() async {
        let mock = MockEngine()
        mock.cleanupRunsHandler = { _, _ in 0 }

        let cmd = try! CleanupCommand.parseAsRoot(["<not-a-date"]) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode with no arguments")
    func noArguments() async {
        let mock = MockEngine()

        let cmd = try! CleanupCommand.parseAsRoot([]) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on conflicting status filters")
    func conflictingStatus() async {
        let mock = MockEngine()
        mock.cleanupRunsHandler = { _, _ in 0 }

        let cmd = try! CleanupCommand.parseAsRoot(
            ["completed", "--status", "failed"]
        ) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode when run ID combined with --older-than")
    func runIDWithOlderThan() async {
        let mock = MockEngine()
        mock.cleanupWorkspaceHandler = { _ in }

        let cmd = try! CleanupCommand.parseAsRoot(
            ["my-run-id", "--older-than", "30d"]
        ) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on invalid --status")
    func invalidStatus() async {
        let mock = MockEngine()
        mock.cleanupRunsHandler = { _, _ in 0 }

        let cmd = try! CleanupCommand.parseAsRoot(["--status", "bogus"]) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on invalid --older-than")
    func invalidOlderThan() async {
        let mock = MockEngine()
        mock.cleanupRunsHandler = { _, _ in 0 }

        let cmd = try! CleanupCommand.parseAsRoot(
            ["all", "--older-than", "xyz"]
        ) as! CleanupCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    // MARK: - Combined Filters

    @Test("positional status with --older-than combines both filters")
    func statusWithOlderThan() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        var receivedStatus: RunStatus?
        mock.cleanupRunsHandler = { date, status in
            receivedDate = date
            receivedStatus = status
            return 1
        }

        let cmd = try CleanupCommand.parseAsRoot(
            ["completed", "--older-than", "7d"]
        ) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
        #expect(receivedStatus == .completed)
    }

    @Test("positional date with --status combines both filters")
    func dateWithStatus() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        var receivedStatus: RunStatus?
        mock.cleanupRunsHandler = { date, status in
            receivedDate = date
            receivedStatus = status
            return 1
        }

        let cmd = try CleanupCommand.parseAsRoot(
            ["<2026-04-15", "--status", "failed"]
        ) as! CleanupCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
        #expect(receivedStatus == .failed)
    }
}
