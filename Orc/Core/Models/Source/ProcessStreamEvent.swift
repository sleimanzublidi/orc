import Foundation

// MARK: - ProcessStreamEvent

/// Events emitted by ProcessRunner during streaming process execution.
/// Yields stdout/stderr chunks as they arrive, followed by a completion event.
public enum ProcessStreamEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case completed(ProcessResult)
}
