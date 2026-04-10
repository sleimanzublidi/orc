import Foundation
import GRDB
import Models

// MARK: - GRDB conformance for RunStats

extension RunStats: TableRecord {
    public static let databaseTableName = "stats"
}

extension RunStats: FetchableRecord {
    public init(row: Row) {
        self.init(
            id: row["id"],
            runID: row["run_id"],
            workflowName: row["workflow_name"],
            // Safe unwrap: fall back to .pending for unknown status values
            // rather than force-unwrapping, per project convention.
            status: {
                let raw: String = row["status"]
                return RunStatus(rawValue: raw) ?? .pending
            }(),
            nodeCount: row["node_count"],
            durationSeconds: row["duration_seconds"],
            completedAt: row["completed_at"]
        )
    }
}

extension RunStats: PersistableRecord {
    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["run_id"] = runID
        container["workflow_name"] = workflowName
        container["status"] = status.rawValue
        container["node_count"] = nodeCount
        container["duration_seconds"] = durationSeconds
        container["completed_at"] = completedAt
    }
}
