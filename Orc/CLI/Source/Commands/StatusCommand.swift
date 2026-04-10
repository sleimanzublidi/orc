import ArgumentParser
import Engine
import Models

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the status of a run"
    )

    @Argument(help: "Run ID.")
    var runID: String

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            guard let run = try await engine.getStatus(runID: runID) else {
                Format.printError("Run '\(runID)' not found.")
                throw ExitCode.failure
            }

            print("Run: \(run.id)")
            print("Workflow: \(run.workflowName)")
            print("Status: \(run.status.rawValue)")
            print("Created: \(Format.date(run.createdAt))")
            print("Updated: \(Format.date(run.updatedAt))")
            if let output = run.output {
                print("Output: \(output)")
            }

            // Show node executions.
            let executions = try await engine.getNodeExecutions(runID: runID, nodeID: nil)
            if !executions.isEmpty {
                print("")
                print("Nodes:")
                let headers = ["NODE", "STATUS", "ATTEMPT", "ITERATION", "STARTED", "COMPLETED"]
                let rows: [[String]] = executions.map { exec in
                    [
                        exec.nodeID,
                        exec.status.rawValue,
                        String(exec.attempt),
                        String(exec.iteration),
                        exec.startedAt.map(Format.date) ?? "-",
                        exec.completedAt.map(Format.date) ?? "-",
                    ]
                }
                Format.printTable(headers: headers, rows: rows)

                // Show hint for awaiting-input nodes.
                // Session-interactive nodes use `orc attach`; prompt nodes use `orc respond`.
                let awaitingNodes = executions.filter { $0.status == NodeStatus.awaitingInput }
                if !awaitingNodes.isEmpty {
                    print("")
                    for node in awaitingNodes {
                        if let message = node.message {
                            print("Node '\(node.nodeID)' is awaiting input: \(message)")
                        } else {
                            print("Node '\(node.nodeID)' is awaiting input.")
                        }
                        if node.tmuxSession != nil {
                            print("  Use: orc attach \(runID) \(node.nodeID)")
                        } else {
                            print("  Use: orc respond \(runID) \(node.nodeID) <response>")
                        }
                    }
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
