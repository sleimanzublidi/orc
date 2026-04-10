import Foundation
import Logging
import Models

/// Handles cancelling running workflows by updating the run and
/// all pending/running node execution records, and destroying any
/// active tmux sessions associated with the run.
///
/// For non-interactive running processes, Swift's cooperative task cancellation
/// is relied upon — the running `Task` in the `NodeDispatcher` is cancelled,
/// which triggers the process runner's cancellation handler. For interactive
/// sessions, the handler explicitly destroys tmux sessions to kill the
/// underlying processes.
struct CancellationHandler: Sendable {
    let store: any WorkflowStoring
    let tmux: any TmuxProviding

    private let logger = Logger(label: "orc.engine.cancellation")

    /// Cancels a running workflow.
    ///
    /// - Parameter runID: The ID of the run to cancel.
    /// - Throws: `EngineError.runNotFound` if no run exists with the given ID.
    func cancel(runID: String) async throws {
        guard let run = try await store.getRun(id: runID) else {
            throw EngineError.runNotFound(id: runID)
        }

        // Only cancel runs that are actually in progress.
        guard run.status == .running || run.status == .awaitingInput || run.status == .pending else {
            return
        }

        // Set run status to cancelled.
        try await store.updateRunStatus(id: runID, status: .cancelled)

        // Mark all pending/running/awaitingInput node executions as cancelled,
        // and destroy any associated tmux sessions.
        let executions = try await store.getNodeExecutions(runID: runID, nodeID: nil)
        for execution in executions {
            if execution.status == .pending || execution.status == .running
                || execution.status == .awaitingInput
            {
                // Destroy tmux session if one exists for this node execution.
                // This kills the underlying process in interactive sessions.
                if let sessionName = execution.tmuxSession {
                    do {
                        try await tmux.destroySession(name: sessionName)
                        logger.info("Destroyed tmux session '\(sessionName)' for node '\(execution.nodeID)'")
                    } catch {
                        // Best-effort: session may already be gone.
                        logger.debug("Could not destroy tmux session '\(sessionName)': \(error)")
                    }
                }

                try await store.updateNodeExecution(
                    id: execution.id,
                    status: .cancelled,
                    output: nil,
                    error: nil
                )
            }
        }
    }
}
