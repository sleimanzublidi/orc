import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("AttachCommand")
struct AttachCommandTests {

    @Test("throws when no execution found (empty array)")
    func throwsWhenNoExecutionFound() async throws {
        let mock = MockEngine()
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let cmd = try AttachCommand.parseAsRoot(["abc", "node1"]) as! AttachCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws when node not awaiting input")
    func throwsWhenNodeNotAwaitingInput() async throws {
        let mock = MockEngine()
        mock.getNodeExecutionsHandler = { _, _ in
            [
                TestFixtures.makeNodeExecution(
                    id: "exec1",
                    runID: "abc",
                    nodeID: "node1",
                    status: .completed
                )
            ]
        }

        let cmd = try AttachCommand.parseAsRoot(["abc", "node1"]) as! AttachCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws when no tmux session (prompt-interactive node)")
    func throwsWhenNoTmuxSession() async throws {
        let mock = MockEngine()
        mock.getNodeExecutionsHandler = { _, _ in
            [
                TestFixtures.makeNodeExecution(
                    id: "exec1",
                    runID: "abc",
                    nodeID: "node1",
                    status: .awaitingInput,
                    tmuxSession: nil,
                    completedAt: nil
                )
            ]
        }

        let cmd = try AttachCommand.parseAsRoot(["abc", "node1"]) as! AttachCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("returns session name when valid")
    func returnsSessionNameWhenValid() async throws {
        let mock = MockEngine()
        mock.getNodeExecutionsHandler = { _, _ in
            [
                TestFixtures.makeNodeExecution(
                    id: "exec1",
                    runID: "abc",
                    nodeID: "node1",
                    status: .awaitingInput,
                    tmuxSession: "orc-abc-node1",
                    completedAt: nil
                )
            ]
        }

        let cmd = try AttachCommand.parseAsRoot(["abc", "node1"]) as! AttachCommand
        let sessionName = try await cmd.execute(engine: mock)

        #expect(sessionName == "orc-abc-node1")
    }

    @Test("passes runID and nodeID to engine")
    func passesRunIDAndNodeID() async throws {
        let mock = MockEngine()
        var receivedRunID: String?
        var receivedNodeID: String?
        mock.getNodeExecutionsHandler = { runID, nodeID in
            receivedRunID = runID
            receivedNodeID = nodeID
            return [
                TestFixtures.makeNodeExecution(
                    id: "exec1",
                    runID: "run99",
                    nodeID: "deploy",
                    status: .awaitingInput,
                    tmuxSession: "orc-run99-deploy",
                    completedAt: nil
                )
            ]
        }

        let cmd = try AttachCommand.parseAsRoot(["run99", "deploy"]) as! AttachCommand
        _ = try await cmd.execute(engine: mock)

        #expect(receivedRunID == "run99")
        #expect(receivedNodeID == "deploy")
    }

    @Test("throws ExitCode.failure when engine throws")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.getNodeExecutionsHandler = { _, _ in
            throw EngineError.runNotFound(id: "abc")
        }

        let cmd = try! AttachCommand.parseAsRoot(["abc", "node1"]) as! AttachCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
