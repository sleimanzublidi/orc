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

    // MARK: - Completion Hook Flags

    @Test("--notify flag parses correctly")
    func notifyFlagParses() throws {
        let cmd = try StartCommand.parseAsRoot([
            "test.yaml", "--notify",
        ]) as! StartCommand
        #expect(cmd.notify == true)
    }

    @Test("--on-complete option parses correctly")
    func onCompleteOptionParses() throws {
        let cmd = try StartCommand.parseAsRoot([
            "test.yaml", "--on-complete", "echo done",
        ]) as! StartCommand
        #expect(cmd.onComplete == "echo done")
    }

    @Test("both --notify and --on-complete can be used together")
    func notifyAndOnCompleteTogether() throws {
        let cmd = try StartCommand.parseAsRoot([
            "test.yaml", "--notify", "--on-complete", "slack-notify",
        ]) as! StartCommand
        #expect(cmd.notify == true)
        #expect(cmd.onComplete == "slack-notify")
    }

    @Test("notificationScript includes run ID, status, and duration for completed run")
    func notificationScriptCompleted() {
        let run = TestFixtures.makeRun(id: "abc123", workflowName: "deploy", status: .completed)
        let script = StartCommand.notificationScript(run: run, elapsedSeconds: 90)
        #expect(script.contains("abc123"))
        #expect(script.contains("completed"))
        #expect(script.contains("Orc \u{2014} Completed"))
        #expect(script.contains("1m 30s"))
    }

    @Test("notificationScript uses failure title for failed runs")
    func notificationScriptFailed() {
        let run = TestFixtures.makeRun(id: "xyz789", status: .failed)
        let script = StartCommand.notificationScript(run: run, elapsedSeconds: 5)
        #expect(script.contains("Orc \u{2014} Failed"))
        #expect(script.contains("failed"))
    }

    @Test("completionEnvironment includes all required variables")
    func completionEnvironmentContent() {
        let run = TestFixtures.makeRun(
            id: "run42",
            workflowName: "deploy",
            status: .completed
        )
        let env = StartCommand.completionEnvironment(run: run, elapsedSeconds: 125.7)
        #expect(env["ORC_RUN_ID"] == "run42")
        #expect(env["ORC_STATUS"] == "completed")
        #expect(env["ORC_ELAPSED_SECONDS"] == "125")
        #expect(env["ORC_WORKFLOW_NAME"] == "deploy")
    }

    @Test("completionEnvironment uses raw status value for awaiting_input")
    func completionEnvironmentAwaitingInput() {
        let run = TestFixtures.makeRun(status: .awaitingInput)
        let env = StartCommand.completionEnvironment(run: run, elapsedSeconds: 0)
        #expect(env["ORC_STATUS"] == "awaiting_input")
    }
}
