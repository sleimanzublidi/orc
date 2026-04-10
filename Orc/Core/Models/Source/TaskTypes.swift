// MARK: - TaskContext

/// Runtime context passed to agents and templates during node execution.
/// Contains resolved inputs, accumulated outputs from prior nodes,
/// and the current workspace path.
public struct TaskContext: Sendable, Equatable, Codable {
    public let inputs: [String: String]
    public let outputs: [String: String]
    public let nodeStatuses: [String: NodeStatus]
    public let workspacePath: String

    public init(
        inputs: [String: String] = [:],
        outputs: [String: String] = [:],
        nodeStatuses: [String: NodeStatus] = [:],
        workspacePath: String
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.nodeStatuses = nodeStatuses
        self.workspacePath = workspacePath
    }
}

// MARK: - TaskOutput

/// The result returned by an agent after executing a prompt.
public struct TaskOutput: Sendable, Equatable, Codable {
    public let output: String
    public let exitStatus: Int

    public init(
        output: String,
        exitStatus: Int = 0
    ) {
        self.output = output
        self.exitStatus = exitStatus
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
