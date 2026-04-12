import Foundation
import Logging
import Models

/// Maps a `WorkflowEvent` stream to `MonitorEvent`s for SSE delivery.
///
/// Used when the workflow was started by the same process (e.g., `orc start --monitor`),
/// providing real-time events without polling. For standalone `orc monitor`, the
/// `PollingEventSource` is still used since it observes already-running workflows.
final class StreamingEventSource: EventProviding, Sendable {
    private let workflowEvents: AsyncThrowingStream<WorkflowEvent, any Error>
    private let logger: Logger
    private let state = ShutdownState()

    init(
        workflowEvents: AsyncThrowingStream<WorkflowEvent, any Error>,
        logger: Logger = Logger(label: "orc.server.streaming-events")
    ) {
        self.workflowEvents = workflowEvents
        self.logger = logger
    }

    func events() -> AsyncStream<MonitorEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                do {
                    for try await event in workflowEvents {
                        if await state.isShutdown { break }

                        let monitorEvents = self.mapEvent(event)
                        for monitorEvent in monitorEvents {
                            continuation.yield(monitorEvent)
                        }
                    }
                } catch {
                    logger.error("Streaming event source error: \(error)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shutdown() async {
        await state.setShutdown()
    }

    /// Maps a `WorkflowEvent` to zero or more `MonitorEvent`s.
    ///
    /// Most events map 1:1 except `nodeOutput` which has no SSE equivalent yet
    /// (output chunk streaming over SSE is out of scope for the current design).
    private func mapEvent(_ event: WorkflowEvent) -> [MonitorEvent] {
        switch event {
        case .runStarted(let run):
            return [.runCreated(run)]

        case .runCompleted(let run):
            return [.runUpdated(run)]

        case .runFailed(let run, _):
            return [.runUpdated(run)]

        case .nodeStarted(let nodeID, let runID, let agent):
            let execution = NodeExecution(
                id: UUID().uuidString,
                runID: runID,
                nodeID: nodeID,
                status: .running,
                agent: agent,
                startedAt: Date()
            )
            return [.nodeUpdated(execution)]

        case .nodeCompleted(let nodeID, let runID, let output):
            let execution = NodeExecution(
                id: UUID().uuidString,
                runID: runID,
                nodeID: nodeID,
                status: .completed,
                output: output,
                completedAt: Date()
            )
            return [.nodeUpdated(execution)]

        case .nodeFailed(let nodeID, let runID, let error):
            let execution = NodeExecution(
                id: UUID().uuidString,
                runID: runID,
                nodeID: nodeID,
                status: .failed,
                error: error,
                completedAt: Date()
            )
            return [.nodeUpdated(execution)]

        case .nodeSkipped(let nodeID, let runID):
            let execution = NodeExecution(
                id: UUID().uuidString,
                runID: runID,
                nodeID: nodeID,
                status: .skipped,
                completedAt: Date()
            )
            return [.nodeUpdated(execution)]

        case .nodeOutput:
            // No SSE event type for output chunks yet (design spec: out of scope)
            return []
        }
    }
}

/// Thread-safe shutdown state for `StreamingEventSource`.
private actor ShutdownState {
    var isShutdown = false
    func setShutdown() { isShutdown = true }
}
