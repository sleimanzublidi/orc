import ArgumentParser
import Engine
import Foundation

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new Orc project"
    )

    @Flag(name: .long, help: "Update defaults in an existing project. New files are added; existing files are preserved unless --force is also passed.")
    var update: Bool = false

    @Flag(name: .long, help: "Used with --update to overwrite existing default files.")
    var force: Bool = false

    func validate() throws {
        if force && !update {
            throw ValidationError("--force requires --update.")
        }
    }

    func run() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let orcDir = cwd.appendingPathComponent(".orc")

        do {
            if update {
                guard FileManager.default.fileExists(atPath: orcDir) else {
                    Format.printError("No Orc project found. Run 'orc init' first.")
                    throw ExitCode.failure
                }
                let actions = try DefaultsWriter.write(to: orcDir, force: force)
                if actions.isEmpty {
                    print("All defaults are up to date.")
                } else {
                    for action in actions {
                        switch action {
                        case .added(let path):
                            print("  added: \(path)")
                        case .replaced(let path):
                            print("  replaced: \(path)")
                        }
                    }
                    print("\(actions.count) file(s) updated.")
                }
            } else {
                try await WorkflowEngine.initializeProject(at: cwd)
                _ = try DefaultsWriter.write(to: orcDir, force: true)
                print("Initialized Orc project at \(orcDir)")
                print("  config.yml  - project configuration")
                print("  orc.db      - run database")
                print("  evaluators/ - custom evaluator scripts")
                print("  workflows/  - workflow definitions")
            }
        } catch let error as ExitCode {
            throw error
        } catch let error as EngineError {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        } catch {
            Format.printError("Error initializing project: \(error)")
            throw ExitCode.failure
        }
    }
}
