import ArgumentParser
import Engine
import Models

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List workflow runs",
        discussion: """
            By default, shows only top-level runs (hides child/nested workflow runs).
            Use --all to include child runs.
            """
    )

    @Option(name: .long, help: "Filter by status (pending, running, completed, failed, cancelled, awaiting_input).")
    var status: String?

    @Flag(name: .long, help: "Include child runs from nested workflows.")
    var all = false

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            // Parse status filter if provided.
            let statusFilter: RunStatus?
            if let statusStr = status {
                guard let parsed = RunStatus(rawValue: statusStr) else {
                    Format.printError("Unknown status '\(statusStr)'. Valid values: pending, running, completed, failed, cancelled, awaiting_input.")
                    throw ExitCode.failure
                }
                statusFilter = parsed
            } else {
                statusFilter = nil
            }

            let runs = try await engine.listRuns(status: statusFilter, topLevelOnly: !all)

            if runs.isEmpty {
                print("No runs found.")
                return
            }

            let headers = ["ID", "WORKFLOW", "STATUS", "CREATED", "UPDATED"]
            let rows = runs.map { run in
                [
                    run.id,
                    run.workflowName,
                    run.status.rawValue,
                    Format.date(run.createdAt),
                    Format.date(run.updatedAt),
                ]
            }

            Format.printTable(headers: headers, rows: rows)
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
