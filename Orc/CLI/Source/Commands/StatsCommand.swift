import ArgumentParser
import Engine
import Foundation
import Models

struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show project statistics"
    )

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            // Database info.
            let dbPath = engine.basePath.appendingPathComponent("orc.db")
            let fm = FileManager.default
            print("Database: \(dbPath)")
            if let attrs = try? fm.attributesOfItem(atPath: dbPath),
               let size = attrs[.size] as? UInt64 {
                print("Database size: \(Format.fileSize(size))")
            }

            // Workspace info.
            let workspacesDir = engine.basePath.appendingPathComponent("workspaces")
            if fm.fileExists(atPath: workspacesDir),
               let contents = try? fm.contentsOfDirectory(atPath: workspacesDir) {
                let workspaceCount = contents.filter { !$0.hasPrefix(".") }.count
                print("Active workspaces: \(workspaceCount)")
            } else {
                print("Active workspaces: 0")
            }

            // Run counts.
            let allRuns = try await engine.listRuns(status: nil)
            let runsByStatus = Dictionary(grouping: allRuns, by: \.status)
            print("")
            print("Runs: \(allRuns.count) total")
            for status in [RunStatus.completed, .failed, .running, .cancelled, .pending, .awaitingInput] {
                let count = runsByStatus[status]?.count ?? 0
                if count > 0 {
                    print("  \(status.rawValue): \(count)")
                }
            }

            // Historical stats.
            let stats = try await engine.getStats()
            if !stats.isEmpty {
                print("")
                print("Recent runs:")
                let headers = ["RUN ID", "WORKFLOW", "STATUS", "NODES", "DURATION", "COMPLETED"]
                let rows = stats.prefix(10).map { stat in
                    [
                        stat.runID,
                        stat.workflowName,
                        stat.status.rawValue,
                        String(stat.nodeCount),
                        stat.durationSeconds.map(Format.duration) ?? "-",
                        Format.date(stat.completedAt),
                    ]
                }
                Format.printTable(headers: headers, rows: rows)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
