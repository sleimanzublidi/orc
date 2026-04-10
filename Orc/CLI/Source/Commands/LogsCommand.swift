import ArgumentParser
import Engine
import Foundation
import Models

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show logs for a run"
    )

    @Argument(help: "Run ID.")
    var runID: String

    @Option(name: .long, help: "Filter by node ID.")
    var node: String?

    @Option(name: .long, help: "Filter by attempt number.")
    var attempt: Int?

    @Option(name: .long, help: "Filter by iteration number.")
    var iteration: Int?

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            let logs = try await engine.getLogs(
                runID: runID,
                nodeID: node,
                attempt: attempt,
                iteration: iteration
            )

            if logs.isEmpty {
                print("No logs found for run '\(runID)'.")
                return
            }

            let fm = FileManager.default
            for entry in logs {
                // Print a header for each log entry.
                print("--- [\(entry.stream.rawValue)] \(Format.date(entry.timestamp)) ---")

                // Read and print the log file content.
                if fm.fileExists(atPath: entry.filePath),
                   let data = fm.contents(atPath: entry.filePath),
                   let content = String(data: data, encoding: .utf8) {
                    print(content, terminator: content.hasSuffix("\n") ? "" : "\n")
                } else {
                    print("(log file not found: \(entry.filePath))")
                }
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
