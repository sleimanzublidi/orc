import ArgumentParser
import Engine
import Logging
import Models

struct ResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume a failed or awaiting-input run"
    )

    @Argument(help: "Run ID to resume.")
    var runID: String

    @Flag(name: .long, help: "Enable verbose output (debug-level logging).")
    var verbose: Bool = false

    func run() async throws {
        let basePath = try OrcDirectory.require()

        let configManager = ConfigManager(basePath: basePath)
        let config = try configManager.loadConfig()
        let isVerbose = verbose || config.verbose

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = isVerbose ? .debug : .info
            return handler
        }

        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            let run = try await engine.resume(runID: runID)

            print("Run \(run.id) \(Format.statusIndicator(run.status))")
            if let output = run.output {
                print("Output: \(output)")
            }
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

