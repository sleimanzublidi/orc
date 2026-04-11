import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("StartCommand")
struct StartCommandTests {

    @Test("passes workflow file, parsed inputs, and maxParallelNodes to engine")
    func passesAllParameters() async throws {
        let mock = MockEngine()
        var receivedFile: String?
        var receivedInputs: [String: String]?
        var receivedMaxNodes: Int?
        mock.startHandler = { file, inputs, maxNodes in
            receivedFile = file
            receivedInputs = inputs
            receivedMaxNodes = maxNodes
            return TestFixtures.makeRun(status: .completed)
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let cmd = try StartCommand.parseAsRoot([
            "deploy.yaml",
            "--input", "env=prod",
            "--input", "region=us-east-1",
            "--max-parallel-nodes", "4",
        ]) as! StartCommand
        try await cmd.execute(engine: mock)

        #expect(receivedFile == "deploy.yaml")
        #expect(receivedInputs == ["env": "prod", "region": "us-east-1"])
        #expect(receivedMaxNodes == 4)
    }

    @Test("succeeds with no inputs")
    func succeedsWithNoInputs() async throws {
        let mock = MockEngine()
        var receivedInputs: [String: String]?
        var receivedMaxNodes: Int?
        mock.startHandler = { _, inputs, maxNodes in
            receivedInputs = inputs
            receivedMaxNodes = maxNodes
            return TestFixtures.makeRun(status: .completed)
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let cmd = try StartCommand.parseAsRoot(["simple.yaml"]) as! StartCommand
        try await cmd.execute(engine: mock)

        #expect(receivedInputs == [:])
        #expect(receivedMaxNodes == nil)
    }

    @Test("throws ExitCode.failure when engine throws")
    func engineErrorThrowsFailure() async throws {
        let mock = MockEngine()
        mock.startHandler = { _, _, _ in
            throw EngineError.workflowAlreadyRunning(id: "dup")
        }

        let cmd = try StartCommand.parseAsRoot(["fail.yaml"]) as! StartCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
