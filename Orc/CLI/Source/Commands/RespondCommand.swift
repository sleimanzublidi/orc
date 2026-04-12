import ArgumentParser
import Engine
import Foundation

struct RespondCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "respond",
        abstract: "Respond to an interactive node awaiting input"
    )

    @Argument(help: "Run ID.")
    var runID: String

    @Argument(help: "Node ID.")
    var nodeID: String

    @Argument(help: "Response text.")
    var text: String?

    @Option(name: .long, help: "Path to a file containing the response.")
    var file: String?

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            // Determine the response text from either argument or file.
            let response: String
            if let filePath = file {
                // Per design spec: copy the file into the workspace artifacts/ directory
                // and send the workspace-relative path as the response.
                let sourceURL = URL(fileURLWithPath: filePath)
                let filename = sourceURL.lastPathComponent
                let fm = FileManager.default

                // Verify source file exists and is readable.
                guard fm.isReadableFile(atPath: filePath) else {
                    Format.printError("Cannot read file '\(filePath)'.")
                    throw ExitCode.failure
                }

                // Get the run's workspace path from the engine.
                guard let run = try await engine.getStatus(runID: runID) else {
                    Format.printError("Run '\(runID)' not found.")
                    throw ExitCode.failure
                }

                let artifactsDir = run.workspacePath.appendingPathComponent("artifacts")
                // Ensure the artifacts directory exists.
                if !fm.fileExists(atPath: artifactsDir) {
                    try fm.createDirectory(atPath: artifactsDir, withIntermediateDirectories: true)
                }

                let destPath = artifactsDir.appendingPathComponent(filename)
                // Remove any existing file at the destination to allow overwrite.
                if fm.fileExists(atPath: destPath) {
                    try fm.removeItem(atPath: destPath)
                }
                try fm.copyItem(atPath: filePath, toPath: destPath)

                // The response is the workspace-relative path.
                response = "artifacts/\(filename)"
            } else if let textValue = text {
                response = textValue
            } else {
                Format.printError("Provide response text as an argument or use --file <path>.")
                throw ExitCode.failure
            }

            try await engine.respond(runID: runID, nodeID: nodeID, response: response)

            print("Response sent to node '\(nodeID)' in run '\(runID)'.")
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
