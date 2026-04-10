import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("ValidateCommand")
struct ValidateCommandTests {

    @Test("succeeds for valid workflow with no errors")
    func succeedsForValidWorkflow() async throws {
        let mock = MockEngine()
        mock.validateHandler = { _ in
            let workflow = TestFixtures.makeWorkflow(name: "deploy", nodeCount: 3, inputCount: 2)
            let result = TestFixtures.makeValidationResult()
            return (workflow, result)
        }

        let cmd = try ValidateCommand.parseAsRoot(["deploy.yaml"]) as! ValidateCommand
        try await cmd.execute(engine: mock)
    }

    @Test("prints warnings for valid workflow with warnings")
    func printsWarningsForValidWorkflow() async throws {
        let mock = MockEngine()
        mock.validateHandler = { _ in
            let workflow = TestFixtures.makeWorkflow(name: "deploy")
            let result = TestFixtures.makeValidationResult(
                warnings: [
                    ValidationError(message: "Node has no dependencies", nodeID: "node0"),
                    ValidationError(message: "Unused input variable"),
                ]
            )
            return (workflow, result)
        }

        // Should succeed (warnings don't cause failure) but print warning lines.
        let cmd = try ValidateCommand.parseAsRoot(["deploy.yaml"]) as! ValidateCommand
        try await cmd.execute(engine: mock)
    }

    @Test("throws exit code 2 for invalid workflow")
    func throwsExitCode2ForInvalidWorkflow() async throws {
        let mock = MockEngine()
        mock.validateHandler = { _ in
            let workflow = TestFixtures.makeWorkflow(name: "broken")
            let result = TestFixtures.makeValidationResult(
                errors: [
                    ValidationError(message: "Cyclic dependency detected", nodeID: "node0"),
                    ValidationError(message: "Missing required input"),
                ]
            )
            return (workflow, result)
        }

        let cmd = try ValidateCommand.parseAsRoot(["broken.yaml"]) as! ValidateCommand

        await #expect {
            try await cmd.execute(engine: mock)
        } throws: { error in
            (error as? ExitCode)?.rawValue == 2
        }
    }

    @Test("throws exit code 2 on EngineError")
    func throwsExitCode2OnEngineError() async throws {
        let mock = MockEngine()
        mock.validateHandler = { _ in
            throw EngineError.runNotFound(id: "missing")
        }

        let cmd = try ValidateCommand.parseAsRoot(["missing.yaml"]) as! ValidateCommand

        await #expect {
            try await cmd.execute(engine: mock)
        } throws: { error in
            (error as? ExitCode)?.rawValue == 2
        }
    }
}
