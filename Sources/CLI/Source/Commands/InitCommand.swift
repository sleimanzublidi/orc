import ArgumentParser
import Engine
import Foundation

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new Orc project"
    )

    func run() async throws {
        let cwd = FileManager.default.currentDirectoryPath

        do {
            try await WorkflowEngine.initializeProject(at: cwd)

            let orcDir = (cwd as NSString).appendingPathComponent(".orc")
            print("Initialized Orc project at \(orcDir)")
            print("  config.yml  - project configuration")
            print("  orc.db      - run database")
            print("  evaluators/ - custom evaluator scripts")
            print("  workflows/  - workflow definitions")
        } catch let error as EngineError {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        } catch {
            Format.printError("Error initializing project: \(error)")
            throw ExitCode.failure
        }
    }
}
