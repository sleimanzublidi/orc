import Foundation

// MARK: - WorkflowEvent

/// Events emitted during streaming workflow execution.
/// Consumers (CLI, web monitor) observe these to display real-time progress.
public enum WorkflowEvent: Sendable {
    case runStarted(Run)
    case runCompleted(Run)
    case runFailed(Run, error: String)
    case nodeStarted(nodeID: String, runID: String, agent: String)
    case nodeOutput(nodeID: String, runID: String, chunk: String, stream: OutputStreamType)
    case nodeCompleted(nodeID: String, runID: String, output: String?)
    case nodeFailed(nodeID: String, runID: String, error: String)
    case nodeSkipped(nodeID: String, runID: String)
}

// MARK: - OutputStreamType

/// Identifies which output stream a chunk originated from.
public enum OutputStreamType: String, Sendable, Codable {
    case stdout
    case stderr
}
