import Foundation
import GRDB
import Models

// MARK: - GRDB conformance for NodeExecution

extension NodeExecution: TableRecord {
    public static let databaseTableName = "node_executions"
}

extension NodeExecution: FetchableRecord {
    public init(row: Row) {
        self.init(
            id: row["id"],
            runID: row["run_id"],
            nodeID: row["node_id"],
            // Safe unwrap: fall back to .pending for unknown status values
            // rather than force-unwrapping, per project convention.
            status: {
                let raw: String = row["status"]
                return NodeStatus(rawValue: raw) ?? .pending
            }(),
            agent: row["agent"],
            attempt: row["attempt"],
            iteration: row["iteration"],
            prompt: row["prompt"],
            message: row["message"],
            output: row["output"],
            error: row["error"],
            tmuxSession: row["tmux_session"],
            startedAt: row["started_at"],
            completedAt: row["completed_at"]
        )
    }
}

extension NodeExecution: PersistableRecord {
    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["run_id"] = runID
        container["node_id"] = nodeID
        container["status"] = status.rawValue
        container["agent"] = agent
        container["attempt"] = attempt
        container["iteration"] = iteration
        container["prompt"] = prompt
        container["message"] = message
        container["output"] = output
        container["error"] = error
        container["tmux_session"] = tmuxSession
        container["started_at"] = startedAt
        container["completed_at"] = completedAt
    }
}
