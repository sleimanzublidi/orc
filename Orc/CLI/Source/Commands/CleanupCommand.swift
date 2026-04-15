import ArgumentParser
import Engine
import Foundation
import Models

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Remove workspaces for runs",
        discussion: """
            Removes workspace directories from disk without deleting database records.

            FILTER can be a run ID, a status name, 'all', or '<YYYY-MM-DD':
              orc cleanup <runID>          Remove workspace for a single run
              orc cleanup all              Remove all workspaces
              orc cleanup completed        Remove workspaces for completed runs
              orc cleanup '<2026-04-15'    Remove workspaces for runs before that date

            Named options work alongside or instead of the positional filter:
              orc cleanup --status failed --older-than 30d
              orc cleanup completed --older-than 7d
            """
    )

    @Argument(help: "Run ID, status name, 'all', or '<YYYY-MM-DD'.")
    var filter: String?

    @Option(name: .long, help: "Remove workspaces older than duration or date (e.g., 30d, 2026-04-15).")
    var olderThan: String?

    @Option(name: .long, help: "Filter by status (\(RunFilterParsing.validStatusValues)).")
    var status: String?

    @Flag(name: .long, help: "Show what would be removed without removing.")
    var dryRun = false

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            // Resolve the positional filter.
            var cutoffDate: Date?
            var statusFilter: RunStatus?
            var hasStatusFromPositional = false
            var singleRunID: String?

            if let filter {
                guard let kind = RunFilterParsing.classifyPositional(filter) else {
                    Format.printError(
                        "Invalid date in '\(filter)'. Expected format: <YYYY-MM-DD."
                    )
                    throw ExitCode.failure
                }
                switch kind {
                case .all:
                    hasStatusFromPositional = true
                case .status(let s):
                    statusFilter = s
                    hasStatusFromPositional = true
                case .olderThan(let d):
                    cutoffDate = d
                case .runID(let id):
                    singleRunID = id
                }
            }

            // Parse --older-than.
            if let olderThanStr = olderThan {
                guard cutoffDate == nil else {
                    Format.printError("Cannot specify both a date filter and --older-than.")
                    throw ExitCode.failure
                }
                guard let date = RunFilterParsing.parseDateOrDuration(olderThanStr) else {
                    Format.printError(
                        "Invalid duration '\(olderThanStr)'. Expected: <number>d or YYYY-MM-DD."
                    )
                    throw ExitCode.failure
                }
                cutoffDate = date
            }

            // Parse --status.
            if let statusStr = status {
                guard !hasStatusFromPositional else {
                    Format.printError("Cannot specify both a positional status filter and --status.")
                    throw ExitCode.failure
                }
                if statusStr == "all" {
                    // Explicit "all" — no status filter.
                } else {
                    guard let parsed = RunStatus(rawValue: statusStr) else {
                        Format.printError(
                            "Unknown status '\(statusStr)'. Valid: \(RunFilterParsing.validStatusValues)."
                        )
                        throw ExitCode.failure
                    }
                    statusFilter = parsed
                }
            }

            // Single-run mode.
            if let runID = singleRunID {
                guard cutoffDate == nil, olderThan == nil, status == nil else {
                    Format.printError("Cannot combine a run ID with --older-than or --status.")
                    throw ExitCode.failure
                }
                if dryRun {
                    print("Would remove workspace for run '\(runID)'.")
                    return
                }
                try await engine.cleanupWorkspace(runID: runID)
                print("Workspace for run '\(runID)' removed.")
                return
            }

            // Bulk mode — require at least one filter.
            guard filter != nil || olderThan != nil || status != nil else {
                Format.printError(
                    "Specify a run ID, status, date filter, or 'all'. See 'orc cleanup --help'."
                )
                throw ExitCode.failure
            }

            if dryRun {
                let runs = try await engine.listRuns(status: statusFilter, topLevelOnly: false)
                let targets = filterByDate(runs, cutoff: cutoffDate)
                if targets.isEmpty {
                    print("No matching runs found.")
                } else {
                    print("Would remove workspaces for \(targets.count) run(s):\n")
                    printRunTable(targets)
                }
                return
            }

            let count = try await engine.cleanupRuns(
                olderThan: cutoffDate,
                status: statusFilter
            )
            print("Cleanup complete. Removed workspaces for \(count) run(s).")
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

    // MARK: - Private Helpers

    private func filterByDate(_ runs: [Run], cutoff: Date?) -> [Run] {
        guard let cutoff else { return runs }
        return runs.filter { $0.updatedAt < cutoff }
    }

    private func printRunTable(_ runs: [Run]) {
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
    }
}
