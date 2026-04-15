// MARK: - TaskContext

/// Runtime context passed to agents and templates during node execution.
/// Contains resolved inputs, accumulated outputs from prior nodes,
/// the repository root path (working directory for execution), and the
/// workspace path (for file storage, logs, and artifacts).
public struct TaskContext: Sendable, Equatable, Codable {
    public let inputs: [String: String]
    public let outputs: [String: String]
    public let nodeStatuses: [String: NodeStatus]
    public let repoRoot: String
    public let workspacePath: String
    public let environment: [String: String]

    public init(
        inputs: [String: String] = [:],
        outputs: [String: String] = [:],
        nodeStatuses: [String: NodeStatus] = [:],
        repoRoot: String,
        workspacePath: String,
        environment: [String: String] = [:]
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.nodeStatuses = nodeStatuses
        self.repoRoot = repoRoot
        self.workspacePath = workspacePath
        self.environment = environment
    }
}

// MARK: - TaskOutput

/// The result returned by an agent after executing a prompt.
public struct TaskOutput: Sendable, Equatable, Codable {
    public let output: String
    public let exitStatus: Int
    /// Path to the captured stdout log file (in NSTemporaryDirectory).
    /// The engine is responsible for moving this to the workspace logs directory.
    public let stdoutPath: String?
    /// Path to the captured stderr log file (in NSTemporaryDirectory).
    public let stderrPath: String?

    public init(
        output: String,
        exitStatus: Int = 0,
        stdoutPath: String? = nil,
        stderrPath: String? = nil
    ) {
        self.output = output
        self.exitStatus = exitStatus
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
    }
}

// MARK: - ProcessResult

/// The result of running a subprocess, with paths to captured stdout/stderr files.
public struct ProcessResult: Sendable, Equatable, Codable {
    public let exitCode: Int32
    public let stdoutPath: String
    public let stderrPath: String

    public init(
        exitCode: Int32,
        stdoutPath: String,
        stderrPath: String
    ) {
        self.exitCode = exitCode
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
    }
}
