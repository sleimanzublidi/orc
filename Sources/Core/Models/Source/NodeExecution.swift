import Foundation

// MARK: - NodeStatus

/// The lifecycle status of a single node execution.
public enum NodeStatus: String, Sendable, Equatable, Codable {
    case pending
    case running
    case awaitingInput = "awaiting_input"
    case completed
    case failed
    case skipped
    case cancelled
}

// MARK: - NodeExecution

/// A record of one node's execution within a run, including retries and loop iterations.
public struct NodeExecution: Sendable, Equatable, Codable {
    public let id: String
    public let runID: String
    public let nodeID: String
    public let status: NodeStatus
    public let agent: String?
    public let attempt: Int
    public let iteration: Int
    public let prompt: String?
    public let message: String?
    public let output: String?
    public let error: String?
    public let tmuxSession: String?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        id: String,
        runID: String,
        nodeID: String,
        status: NodeStatus = .pending,
        agent: String? = nil,
        attempt: Int = 1,
        iteration: Int = 1,
        prompt: String? = nil,
        message: String? = nil,
        output: String? = nil,
        error: String? = nil,
        tmuxSession: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.nodeID = nodeID
        self.status = status
        self.agent = agent
        self.attempt = attempt
        self.iteration = iteration
        self.prompt = prompt
        self.message = message
        self.output = output
        self.error = error
        self.tmuxSession = tmuxSession
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
