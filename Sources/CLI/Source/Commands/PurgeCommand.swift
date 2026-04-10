import ArgumentParser
import Engine
import Foundation
import Models

struct PurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Delete old runs and their workspaces"
    )

    @Option(name: .long, help: "Delete runs older than duration (e.g., 30d, 7d).")
    var olderThan: String?

    @Option(name: .long, help: "Filter by status (pending, running, completed, failed, cancelled, awaiting_input, all).")
    var status: String?

    func run() async throws {
        do {
            let basePath = try OrcDirectory.require()
            let engine = try await WorkflowEngine(basePath: basePath)

            // Parse the --older-than duration.
            let cutoffDate: Date?
            if let durationStr = olderThan {
                guard let date = parseDuration(durationStr) else {
                    Format.printError("Invalid duration '\(durationStr)'. Expected format: <number>d (e.g., 30d).")
                    throw ExitCode.failure
                }
                cutoffDate = date
            } else {
                cutoffDate = nil
            }

            // Parse the status filter. "all" means no filter (nil), matching all statuses.
            let statusFilter: RunStatus?
            if let statusStr = status {
                if statusStr == "all" {
                    statusFilter = nil
                } else {
                    guard let parsed = RunStatus(rawValue: statusStr) else {
                        Format.printError("Unknown status '\(statusStr)'. Valid values: pending, running, completed, failed, cancelled, awaiting_input, all.")
                        throw ExitCode.failure
                    }
                    statusFilter = parsed
                }
            } else {
                statusFilter = nil
            }

            try await engine.purge(olderThan: cutoffDate, status: statusFilter)

            var message = "Purge complete."
            if let durationStr = olderThan {
                message += " Removed runs older than \(durationStr)."
            }
            if let statusStr = status {
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
}

/// Parses a duration string like "30d" into a Date in the past.
///
/// Currently supports days only (e.g., "7d", "30d").
///
/// - Parameter duration: The duration string.
/// - Returns: A Date representing now minus the given duration, or nil if unparseable.
private func parseDuration(_ duration: String) -> Date? {
    guard duration.hasSuffix("d"),
          let days = Int(duration.dropLast()),
          days > 0
    else {
        return nil
    }
    return Calendar.current.date(byAdding: .day, value: -days, to: Date())
}
