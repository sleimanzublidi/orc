import Foundation

// MARK: - LogStream

/// Which output stream a log entry was captured from.
public enum LogStream: String, Sendable, Equatable, Codable {
    case stdout
    case stderr
}

// MARK: - LogEntry

/// A log file record linking a node execution to its captured output on disk.
public struct LogEntry: Sendable, Equatable, Codable {
    public let id: Int?
    public let nodeExecutionID: String
    public let stream: LogStream
    public let filePath: String
    public let timestamp: Date

    public init(
        id: Int? = nil,
        nodeExecutionID: String,
        stream: LogStream,
        filePath: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.nodeExecutionID = nodeExecutionID
        self.stream = stream
        self.filePath = filePath
        self.timestamp = timestamp
    }
}
