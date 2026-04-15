import ArgumentParser
import Engine
import Foundation
import Models

struct PurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Delete old runs and their workspaces",
        discussion: """
            Deletes run records from the database and removes their workspace directories.

            FILTER can be a status name, 'all', or '<YYYY-MM-DD':
              orc purge all                Purge all runs
              orc purge completed          Purge completed runs
              orc purge '<2026-04-15'      Purge runs before that date

            Named options work alongside or instead of the positional filter:
              orc purge --status failed --older-than 30d
              orc purge completed --older-than 7d

            With no arguments, purges all runs (same as 'orc purge all').
            """
    )

    @Argument(help: "Status name, 'all', or '<YYYY-MM-DD'.")
    var filter: String?

    @Option(name: .long, help: "Delete runs older than duration or date (e.g., 30d, 2026-04-15).")
    var olderThan: String?

    @Option(name: .long, help: "Filter by status (\(RunFilterParsing.validStatusValues)).")
    var status: String?

    @Flag(name: .long, help: "Show what would be purged without purging.")
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
                case .runID:
                    Format.printError(
                        "Unknown filter '\(filter)'. Expected: all, a status (\(RunFilterParsing.validStatusValues)), or <YYYY-MM-DD."
                    )
                    throw ExitCode.failure
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

            // Dry-run: show what would be purged.
            if dryRun {
                let runs = try await engine.listRuns(status: statusFilter, topLevelOnly: false)
                let targets = filterByDate(runs, cutoff: cutoffDate)
                if targets.isEmpty {
                    print("No matching runs found.")
                } else {
                    print("Would purge \(targets.count) run(s):\n")
                    printRunTable(targets)
                }
                return
            }

            try await engine.purge(olderThan: cutoffDate, status: statusFilter)

            var message = "Purge complete."
            if let olderThanStr = olderThan ?? cutoffDateDescription(cutoffDate) {
                message += " Removed runs older than \(olderThanStr)."
            }
            if let statusStr = status ?? filter.flatMap({ RunStatus(rawValue: $0)?.rawValue }) {
                message += " Status filter: \(statusStr)."
            }
            print(message)
        } catch let error as ExitCode {
            throw error
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

    /// Formats a cutoff date from the positional `<YYYY-MM-DD` for the success message.
    private func cutoffDateDescription(_ date: Date?) -> String? {
        guard date != nil else { return nil }
        // Only show when the date came from the positional (not --older-than).
        guard olderThan == nil, let filter, filter.hasPrefix("<") else { return nil }
        return String(filter.dropFirst())
    }
}
