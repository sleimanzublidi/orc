import Foundation

// MARK: - RunStats

/// Aggregated statistics for a completed workflow run, used for the `stats` CLI command.
public struct RunStats: Sendable, Equatable, Codable {
    public let id: Int?
    public let runID: String
    public let workflowName: String
    public let status: RunStatus
    public let nodeCount: Int
    public let durationSeconds: Double?
    public let completedAt: Date

    public init(
        id: Int? = nil,
        runID: String,
        workflowName: String,
        status: RunStatus,
        nodeCount: Int,
        durationSeconds: Double? = nil,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.workflowName = workflowName
        self.status = status
        self.nodeCount = nodeCount
        self.durationSeconds = durationSeconds
        self.completedAt = completedAt
    }
}
