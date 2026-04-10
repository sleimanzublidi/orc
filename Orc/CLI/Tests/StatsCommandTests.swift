import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("StatsCommand")
struct StatsCommandTests {

    @Test("handles empty runs and stats")
    func handlesEmptyRunsAndStats() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in [] }
        mock.getStatsHandler = { [] }

        let cmd = try StatsCommand.parseAsRoot([]) as! StatsCommand
        try await cmd.execute(engine: mock)
    }

    @Test("handles runs grouped by status")
    func handlesRunsGroupedByStatus() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in
            [
                TestFixtures.makeRun(id: "run1", status: .completed),
                TestFixtures.makeRun(id: "run2", status: .completed),
                TestFixtures.makeRun(id: "run3", status: .failed),
                TestFixtures.makeRun(id: "run4", status: .running),
            ]
        }
        mock.getStatsHandler = { [] }

        let cmd = try StatsCommand.parseAsRoot([]) as! StatsCommand
        // Should succeed and print grouped counts (completed: 2, failed: 1, running: 1).
        try await cmd.execute(engine: mock)
    }

    @Test("shows recent runs table from stats")
    func showsRecentRunsTable() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in
            [TestFixtures.makeRun(id: "run1", status: .completed)]
        }
        mock.getStatsHandler = {
            [
                TestFixtures.makeRunStats(
                    runID: "run1",
                    workflowName: "deploy",
                    status: .completed,
                    nodeCount: 5,
                    durationSeconds: 45.0,
                    completedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                TestFixtures.makeRunStats(
                    runID: "run2",
                    workflowName: "test",
                    status: .failed,
                    nodeCount: 3,
                    durationSeconds: 120.5,
                    completedAt: Date(timeIntervalSince1970: 1_700_001_000)
                ),
            ]
        }

        let cmd = try StatsCommand.parseAsRoot([]) as! StatsCommand
        // Should print the "Recent runs:" table with two entries.
        try await cmd.execute(engine: mock)
    }

    @Test("handles stats with nil duration")
    func handlesStatsWithNilDuration() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in [] }
        mock.getStatsHandler = {
            [
                TestFixtures.makeRunStats(
                    runID: "run1",
                    workflowName: "build",
                    status: .running,
                    nodeCount: 2,
                    durationSeconds: nil
                )
            ]
        }

        let cmd = try StatsCommand.parseAsRoot([]) as! StatsCommand
        // Duration column should show "-" for nil duration.
        try await cmd.execute(engine: mock)
    }

    @Test("uses engine basePath for database and workspace paths")
    func usesEngineBasePath() async throws {
        let mock = MockEngine()
        mock.basePath = "/custom/path/.orc"
        mock.listRunsHandler = { _ in [] }
        mock.getStatsHandler = { [] }

        let cmd = try StatsCommand.parseAsRoot([]) as! StatsCommand
        // Should not throw -- the paths derived from basePath won't exist,
        // but the command handles missing db/workspaces gracefully.
        try await cmd.execute(engine: mock)
    }

    @Test("throws ExitCode.failure when engine throws")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.listRunsHandler = { _ in
            throw EngineError.runNotFound(id: "any")
        }
        mock.getStatsHandler = { [] }

        let cmd = try! StatsCommand.parseAsRoot([]) as! StatsCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
