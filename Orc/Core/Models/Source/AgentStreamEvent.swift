import Foundation

// MARK: - AgentStreamEvent

/// Events emitted by agent providers during streaming execution.
/// Output chunks are decoded to String at the provider level.
public enum AgentStreamEvent: Sendable {
    case output(String, OutputStreamType)
    case completed(TaskOutput)
}
