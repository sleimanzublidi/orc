import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("StatusCommand")
struct StatusCommandTests {

    // MARK: - Run Detail Mode (with run ID)

    @Test("throws ExitCode.failure when run not found")
    func throwsWhenRunNotFound() async throws {
        let mock = MockEngine()
        mock.getStatusHandler = { _ in nil }

        let cmd = try StatusCommand.parseAsRoot(["abc12345"]) as! StatusCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("succeeds when run found with no node executions")
    func succeedsWithNoNodeExecutions() async throws {
        let mock = MockEngine()
        mock.getStatusHandler = { _ in
            TestFixtures.makeRun(id: "abc12345", status: .completed)
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let cmd = try StatusCommand.parseAsRoot(["abc12345"]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    @Test("succeeds when run found with node executions")
    func succeedsWithNodeExecutions() async throws {
        let mock = MockEngine()
        mock.getStatusHandler = { _ in
            TestFixtures.makeRun(id: "run1", status: .running)
        }
        mock.getNodeExecutionsHandler = { _, _ in
            [
                TestFixtures.makeNodeExecution(
                    id: "exec1", runID: "run1", nodeID: "build", status: .completed
                ),
                TestFixtures.makeNodeExecution(
                    id: "exec2", runID: "run1", nodeID: "test", status: .running
                ),
            ]
        }

        let cmd = try StatusCommand.parseAsRoot(["run1"]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    @Test("shows awaiting-input hint with tmux session")
    func awaitingInputWithTmux() async throws {
        let mock = MockEngine()
        mock.getStatusHandler = { _ in
            TestFixtures.makeRun(id: "run1", status: .running)
        }
        mock.getNodeExecutionsHandler = { _, _ in
            [
                TestFixtures.makeNodeExecution(
                    id: "exec1",
                    runID: "run1",
                    nodeID: "interactive-node",
                    status: .awaitingInput,
                    message: "Waiting for approval",
                    tmuxSession: "orc-run1-interactive-node",
                    completedAt: nil
                ),
            ]
        }

        let cmd = try StatusCommand.parseAsRoot(["run1"]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    @Test("shows awaiting-input hint without tmux (prompt-interactive)")
    func awaitingInputWithoutTmux() async throws {
        let mock = MockEngine()
        mock.getStatusHandler = { _ in
            TestFixtures.makeRun(id: "run1", status: .running)
        }
        mock.getNodeExecutionsHandler = { _, _ in
            [
                TestFixtures.makeNodeExecution(
                    id: "exec1",
                    runID: "run1",
                    nodeID: "prompt-node",
                    status: .awaitingInput,
                    message: "Please provide input",
                    tmuxSession: nil,
                    completedAt: nil
                ),
            ]
        }

        let cmd = try StatusCommand.parseAsRoot(["run1"]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    // MARK: - In-Progress Mode (no run ID)

    @Test("no arguments shows in-progress runs")
    func noArgsShowsInProgress() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _, _ in
            [
                TestFixtures.makeRun(id: "run-1", status: .running),
                TestFixtures.makeRun(id: "run-2", status: .completed),
                TestFixtures.makeRun(id: "run-3", status: .pending),
            ]
        }

        let cmd = try StatusCommand.parseAsRoot([]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    @Test("no arguments with no in-progress runs prints message")
    func noArgsNoInProgress() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _, _ in
            [
                TestFixtures.makeRun(id: "run-1", status: .completed),
                TestFixtures.makeRun(id: "run-2", status: .failed),
            ]
        }

        let cmd = try StatusCommand.parseAsRoot([]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    @Test("no arguments with empty run list prints message")
    func noArgsEmptyList() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _, _ in [] }

        let cmd = try StatusCommand.parseAsRoot([]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }

    @Test("no arguments includes awaiting_input runs")
    func noArgsIncludesAwaitingInput() async throws {
        let mock = MockEngine()
        mock.listRunsHandler = { _, _ in
            [
                TestFixtures.makeRun(id: "run-1", status: .awaitingInput),
            ]
        }

        // Should succeed and show the awaiting_input run.
        let cmd = try StatusCommand.parseAsRoot([]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }
}
