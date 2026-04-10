import ArgumentParser
import Engine
import Models
import Testing

@testable import CLI

@Suite("CancelCommand")
struct CancelCommandTests {

    @Test("passes runID to engine.cancel")
    func passesRunID() async throws {
        let mock = MockEngine()
        var receivedID: String?
        mock.cancelHandler = { id in receivedID = id }

        var cmd = CancelCommand()
        cmd.runID = "xyz99999"
        try await cmd.execute(engine: mock)

        #expect(receivedID == "xyz99999")
    }

    @Test("throws ExitCode.failure when engine throws EngineError")
    func engineErrorThrowsFailure() async {
        let mock = MockEngine()
        mock.cancelHandler = { _ in throw EngineError.runNotFound(id: "abc") }

        var cmd = CancelCommand()
        cmd.runID = "abc"

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
