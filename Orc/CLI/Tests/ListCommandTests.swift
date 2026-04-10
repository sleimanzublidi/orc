import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("ListCommand")
struct ListCommandTests {

    @Test("passes nil status when no filter provided")
    func noFilter() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?? = .none
        mock.listRunsHandler = { status in
            receivedStatus = .some(status)
            return []
        }

        let cmd = try ListCommand.parseAsRoot([]) as! ListCommand
        try await cmd.execute(engine: mock)

        // receivedStatus should be .some(nil) -- the handler was called with nil.
        #expect(receivedStatus == .some(nil))
    }

    @Test("passes parsed RunStatus when filter provided")
    func withStatusFilter() async throws {
        let mock = MockEngine()
        var receivedStatus: RunStatus?
        mock.listRunsHandler = { status in
            receivedStatus = status
            return [TestFixtures.makeRun(status: .completed)]
        }

        let cmd = try ListCommand.parseAsRoot(["--status", "completed"]) as! ListCommand
        try await cmd.execute(engine: mock)

        #expect(receivedStatus == .completed)
    }

    @Test("throws ExitCode on invalid status string")
    func invalidStatus() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in [] }

        let cmd = try ListCommand.parseAsRoot(["--status", "bogus"]) as! ListCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("handles empty run list without error")
    func emptyRunList() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in [] }

        let cmd = try ListCommand.parseAsRoot([]) as! ListCommand
        try await cmd.execute(engine: mock)
    }

    @Test("handles non-empty run list without error")
    func nonEmptyRunList() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in
            [
                TestFixtures.makeRun(id: "run-1", workflowName: "deploy", status: .completed),
                TestFixtures.makeRun(id: "run-2", workflowName: "test", status: .running),
            ]
        }

        let cmd = try ListCommand.parseAsRoot([]) as! ListCommand
        try await cmd.execute(engine: mock)
    }
}
