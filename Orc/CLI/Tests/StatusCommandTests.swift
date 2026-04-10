import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("StatusCommand")
struct StatusCommandTests {

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

        // The command should succeed and print the "orc attach" hint.
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

        // The command should succeed and print the "orc respond" hint.
        let cmd = try StatusCommand.parseAsRoot(["run1"]) as! StatusCommand
        try await cmd.execute(engine: mock)
    }
}
