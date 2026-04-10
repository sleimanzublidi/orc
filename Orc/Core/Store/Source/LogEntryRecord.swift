import Foundation
import GRDB
import Models

// MARK: - GRDB conformance for LogEntry

extension LogEntry: TableRecord {
    public static let databaseTableName = "logs"
}

extension LogEntry: FetchableRecord {
    public init(row: Row) {
        self.init(
            id: row["id"],
            nodeExecutionID: row["node_execution_id"],
            // Safe unwrap: fall back to .stdout for unknown stream values
            // rather than force-unwrapping, per project convention.
            stream: {
                let raw: String = row["stream"]
                return LogStream(rawValue: raw) ?? .stdout
            }(),
            filePath: row["file_path"],
            timestamp: row["timestamp"]
        )
    }
}

extension LogEntry: PersistableRecord {
    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["node_execution_id"] = nodeExecutionID
        container["stream"] = stream.rawValue
        container["file_path"] = filePath
        container["timestamp"] = timestamp
    }
}
