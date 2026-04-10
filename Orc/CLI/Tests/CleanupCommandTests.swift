import ArgumentParser
import Engine
import Models
import Testing

@testable import CLI

@Suite("CleanupCommand")
struct CleanupCommandTests {

    @Test("passes runID to engine.cleanupWorkspace")
    func passesRunID() async throws {
        let mock = MockEngine()
        var receivedID: String?
        mock.cleanupWorkspaceHandler = { id in receivedID = id }

        var cmd = CleanupCommand()
        cmd.runID = "run-cleanup-1"
        try await cmd.execute(engine: mock)

        #expect(receivedID == "run-cleanup-1")
    }

    @Test("throws ExitCode.failure when engine throws EngineError")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.cleanupWorkspaceHandler = { id in
            throw EngineError.workspaceNotFound(runID: id)
        }

        var cmd = CleanupCommand()
        cmd.runID = "no-workspace"

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
