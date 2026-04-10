import ArgumentParser
import Engine
import Models

struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a workflow YAML file"
    )

    @Argument(help: "Path to the workflow YAML file.")
    var workflowFile: String

    func run() async throws {
        do {
            let basePath = try OrcDirectory.require()
            let engine = try await WorkflowEngine(basePath: basePath)
            let (workflow, result) = try await engine.validate(workflowFile: workflowFile)

            if !result.warnings.isEmpty {
                for warning in result.warnings {
                    let prefix = warning.nodeID.map { "[\($0)] " } ?? ""
                    print("warning: \(prefix)\(warning.message)")
                }
            }

            if result.isValid {
                print("Workflow '\(workflow.name)' is valid.")
                print("  Nodes: \(workflow.nodes.count)")
                print("  Inputs: \(workflow.input.count)")
            } else {
                Format.printError("Validation failed with \(result.errors.count) error(s):")
                for error in result.errors {
                    let prefix = error.nodeID.map { "[\($0)] " } ?? ""
                    Format.printError("  - \(prefix)\(error.message)")
                }
                throw ExitCode(rawValue: 2)
            }
        } catch let error as ExitCode {
            throw error
        } catch let error as EngineError {
            Format.printError("Engine error: \(error)")
            throw ExitCode(rawValue: 2)
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
