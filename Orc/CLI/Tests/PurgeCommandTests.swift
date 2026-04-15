import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("PurgeCommand")
struct PurgeCommandTests {

    // MARK: - No Arguments (purge all)

    @Test("passes nil for both options when none provided")
    func noOptions() async throws {
        let mock = MockEngine()
        var receivedDate: Date?? = .none
        var receivedStatus: RunStatus?? = .none
        mock.purgeHandler = { date, status in
            receivedDate = .some(date)
            receivedStatus = .some(status)
        }

        let cmd = try PurgeCommand.parseAsRoot([]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate == .some(nil))
        #expect(receivedStatus == .some(nil))
    }

    // MARK: - Positional Filters

    @Test("'all' positional passes nil for both")
    func positionalAll() async throws {
        let mock = MockEngine()
        var receivedDate: Date?? = .none
        var receivedStatus: RunStatus?? = .none
        mock.purgeHandler = { date, status in
            receivedDate = .some(date)
            receivedStatus = .some(status)
        }

        let cmd = try PurgeCommand.parseAsRoot(["all"]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate == .some(nil))
        #expect(receivedStatus == .some(nil))
    }

    @Test("'completed' positional passes status filter")
    func positionalStatus() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?
        mock.purgeHandler = { _, status in
            receivedStatus = status
        }

        let cmd = try PurgeCommand.parseAsRoot(["completed"]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedStatus == .completed)
    }

    @Test("'<2026-04-15' positional passes cutoff date")
    func positionalDate() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        mock.purgeHandler = { date, _ in
            receivedDate = date
        }

        let cmd = try PurgeCommand.parseAsRoot(["<2026-04-15"]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: receivedDate!
        )
        #expect(components.year == 2026)
        #expect(components.month == 4)
        #expect(components.day == 15)
    }

    // MARK: - Named Options (backward-compatible)

    @Test("parses --older-than '30d' into a Date ~30 days ago")
    func parsesOlderThan30d() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        mock.purgeHandler = { date, _ in
            receivedDate = date
        }

        let cmd = try PurgeCommand.parseAsRoot(["--older-than", "30d"]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        let expected = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        #expect(receivedDate != nil)
        #expect(abs(receivedDate!.timeIntervalSince(expected)) < 1.0)
    }

    @Test("--older-than accepts ISO date string")
    func olderThanISODate() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        mock.purgeHandler = { date, _ in
            receivedDate = date
        }

        let cmd = try PurgeCommand.parseAsRoot(
            ["--older-than", "2026-01-01"]
        ) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
    }

    @Test("status 'all' maps to nil status filter")
    func statusAllMapsToNil() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?? = .none
        mock.purgeHandler = { _, status in
            receivedStatus = .some(status)
        }

        let cmd = try PurgeCommand.parseAsRoot(["--status", "all"]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedStatus == .some(nil))
    }

    // MARK: - Combined Filters

    @Test("positional status with --older-than combines both")
    func statusWithOlderThan() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        var receivedStatus: RunStatus?
        mock.purgeHandler = { date, status in
            receivedDate = date
            receivedStatus = status
        }

        let cmd = try PurgeCommand.parseAsRoot(
            ["completed", "--older-than", "7d"]
        ) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
        #expect(receivedStatus == .completed)
    }

    @Test("positional date with --status combines both")
    func dateWithStatus() async throws {
        let mock = MockEngine()
        var receivedDate: Date?
        var receivedStatus: RunStatus?
        mock.purgeHandler = { date, status in
            receivedDate = date
            receivedStatus = status
        }

        let cmd = try PurgeCommand.parseAsRoot(
            ["<2026-04-15", "--status", "failed"]
        ) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(receivedDate != nil)
        #expect(receivedStatus == .failed)
    }

    // MARK: - Dry Run

    @Test("--dry-run shows list without purging")
    func dryRun() async throws {
        let mock = MockEngine()
        var purgeCalled = false
        mock.purgeHandler = { _, _ in purgeCalled = true }
        mock.listRunsHandler = { _, _ in
            [TestFixtures.makeRun(id: "run-1", status: .completed)]
        }

        let cmd = try PurgeCommand.parseAsRoot(["completed", "--dry-run"]) as! PurgeCommand
        try await cmd.execute(engine: mock)

        #expect(!purgeCalled)
    }

    @Test("--dry-run with no matching runs prints message")
    func dryRunEmpty() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _, _ in [] }

        let cmd = try PurgeCommand.parseAsRoot(["--dry-run"]) as! PurgeCommand
        try await cmd.execute(engine: mock)
    }

    // MARK: - Error Cases

    @Test("throws ExitCode on invalid duration string")
    func invalidDuration() async throws {
        let mock = MockEngine()
        mock.purgeHandler = { _, _ in }

        let cmd = try PurgeCommand.parseAsRoot(
            ["--older-than", "notaduration"]
        ) as! PurgeCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on invalid status string")
    func invalidStatus() async throws {
        let mock = MockEngine()
        mock.purgeHandler = { _, _ in }

        let cmd = try PurgeCommand.parseAsRoot(["--status", "bogus"]) as! PurgeCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on invalid date filter")
    func invalidDateFilter() async {
        let mock = MockEngine()
        mock.purgeHandler = { _, _ in }

        let cmd = try! PurgeCommand.parseAsRoot(["<not-a-date"]) as! PurgeCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on unrecognized positional (not a status or date)")
    func unrecognizedPositional() async {
        let mock = MockEngine()
        mock.purgeHandler = { _, _ in }

        let cmd = try! PurgeCommand.parseAsRoot(["some-run-id"]) as! PurgeCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on conflicting status filters")
    func conflictingStatus() async {
        let mock = MockEngine()
        mock.purgeHandler = { _, _ in }

        let cmd = try! PurgeCommand.parseAsRoot(
            ["completed", "--status", "failed"]
        ) as! PurgeCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws ExitCode on conflicting date filters")
    func conflictingDates() async {
        let mock = MockEngine()
        mock.purgeHandler = { _, _ in }

        let cmd = try! PurgeCommand.parseAsRoot(
            ["<2026-04-15", "--older-than", "30d"]
        ) as! PurgeCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
