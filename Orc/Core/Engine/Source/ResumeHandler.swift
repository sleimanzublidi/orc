import Foundation
import Models

/// Handles resuming failed, cancelled, or awaiting-input runs.
///
/// Validates that the run is in a resumable state, the workspace still exists,
/// and all previously completed nodes still exist in the current workflow definition.
/// Returns the data needed to re-dispatch from the failure point.
struct ResumeHandler: Sendable {
    let store: any WorkflowStoring
    let parser: any WorkflowParsing

    /// Prepares a run for resumption.
    ///
    /// - Parameter runID: The ID of the run to resume.
    /// - Returns: A tuple of (run, workflow, completedOutputs) where completedOutputs
    ///   maps completed node IDs to their outputs for context restoration.
    /// - Throws: `EngineError` if the run cannot be resumed.
    func prepareResume(runID: String) async throws -> (Run, Workflow, [String: String]) {
        // Load the run from the store.
        guard let run = try await store.getRun(id: runID) else {
            throw EngineError.runNotFound(id: runID)
        }

        // The run must be in a resumable state.
        let resumableStatuses: Set<RunStatus> = [.failed, .cancelled, .awaitingInput]
        guard resumableStatuses.contains(run.status) else {
            throw EngineError.runNotResumable(id: runID, status: run.status)
        }

        // Validate workspace still exists on disk.
        let fm = FileManager.default
        guard fm.fileExists(atPath: run.workspacePath) else {
            throw EngineError.workspaceNotFound(runID: runID)
        }

        // Re-parse the current workflow YAML from the run's workflow file.
        let workflow = try parser.parse(file: run.workflowFile)

        // Build a set of current node IDs from the workflow.
        let currentNodeIDs = Set(workflow.nodes.map(\.id))

        // Collect completed node outputs and validate they still exist.
        let executions = try await store.getNodeExecutions(runID: runID, nodeID: nil)
        var completedOutputs: [String: String] = [:]

        for execution in executions where execution.status == .completed {
            // Verify the completed node still exists in the updated workflow.
            guard currentNodeIDs.contains(execution.nodeID) else {
                throw EngineError.completedNodeRemoved(nodeID: execution.nodeID)
            }
            if let output = execution.output {
                completedOutputs[execution.nodeID] = output
            }
        }

        return (run, workflow, completedOutputs)
    }
}
