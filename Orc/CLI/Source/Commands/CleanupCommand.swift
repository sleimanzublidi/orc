import ArgumentParser
import Engine

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Remove workspace for a specific run"
    )

    @Argument(help: "Run ID.")
    var runID: String

    func run() async throws {
        do {
            let basePath = try OrcDirectory.require()
            let engine = try await WorkflowEngine(basePath: basePath)

            try await engine.cleanupWorkspace(runID: runID)

            print("Workspace for run '\(runID)' removed.")
        } catch let error as ExitCode {
            throw error
        } catch let error as EngineError {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
