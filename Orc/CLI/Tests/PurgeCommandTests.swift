import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("PurgeCommand")
struct PurgeCommandTests {

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
        // Allow 1-second tolerance for the time between date creation and comparison.
        #expect(abs(receivedDate!.timeIntervalSince(expected)) < 1.0)
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
}
