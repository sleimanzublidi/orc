import Foundation

// MARK: - RunStatus

/// The lifecycle status of a workflow run.
public enum RunStatus: String, Sendable, Equatable, Codable {
    case pending
    case running
    case awaitingInput = "awaiting_input"
    case completed
    case failed
    case cancelled
}

// MARK: - CleanupPolicy

/// Controls when workspace artifacts are purged after a run completes.
public enum CleanupPolicy: Sendable, Equatable {
    case duration(days: Int)
    case onSuccess
    case always
    case never
}

extension CleanupPolicy: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case "on_success":
            self = .onSuccess
        case "always":
            self = .always
        case "never":
            self = .never
        default:
            // Parse duration format: "30d" -> .duration(days: 30)
            guard value.hasSuffix("d"),
                  let days = Int(value.dropLast()) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown CleanupPolicy value: \(value)"
                )
            }
            self = .duration(days: days)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .duration(let days):
            try container.encode("\(days)d")
        case .onSuccess:
            try container.encode("on_success")
        case .always:
            try container.encode("always")
        case .never:
            try container.encode("never")
        }
    }
}

// MARK: - Run

/// A single execution instance of a workflow.
public struct Run: Sendable, Equatable, Codable {
    public let id: String
    public let workflowName: String
    public let workflowFile: String
    public let status: RunStatus
    public let workspacePath: String
    public let inputs: [String: String]?
    public let output: String?
    public let cleanupPolicy: CleanupPolicy
    /// The run ID of the parent workflow that spawned this child run, or nil for top-level runs.
    public let parentRunID: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        workflowName: String,
        workflowFile: String,
        status: RunStatus = .pending,
        workspacePath: String,
        inputs: [String: String]? = nil,
        output: String? = nil,
        cleanupPolicy: CleanupPolicy = .duration(days: 30),
        parentRunID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workflowName = workflowName
        self.workflowFile = workflowFile
        self.status = status
        self.workspacePath = workspacePath
        self.inputs = inputs
        self.output = output
        self.cleanupPolicy = cleanupPolicy
        self.parentRunID = parentRunID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
