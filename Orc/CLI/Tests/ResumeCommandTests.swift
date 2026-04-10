import ArgumentParser
import Engine
import Models
import Testing

@testable import CLI

@Suite("ResumeCommand")
struct ResumeCommandTests {

    @Test("passes runID to engine.resume")
    func passesRunID() async throws {
        let mock = MockEngine()
        var receivedID: String?
        mock.resumeHandler = { id in
            receivedID = id
            return TestFixtures.makeRun(id: id, status: .completed)
        }

        var cmd = ResumeCommand()
        cmd.runID = "resume-abc"
        try await cmd.execute(engine: mock)

        #expect(receivedID == "resume-abc")
    }

    @Test("throws ExitCode.failure when engine throws EngineError.runNotResumable")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.resumeHandler = { id in
            throw EngineError.runNotResumable(id: id, status: .completed)
        }

        var cmd = ResumeCommand()
        cmd.runID = "not-resumable"

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
