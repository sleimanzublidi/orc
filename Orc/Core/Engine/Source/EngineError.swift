import Foundation
import Models

/// Typed errors for the Engine module, covering workflow execution failures,
/// DAG resolution issues, evaluator problems, and state-related errors.
public enum EngineError: Error, Sendable, Equatable {
    /// Attempted to start a workflow that is already running.
    case workflowAlreadyRunning(id: String)

    /// No run found with the given ID.
    case runNotFound(id: String)

    /// The run cannot be resumed because its status does not allow it
    /// (must be failed, cancelled, or awaiting_input).
    case runNotResumable(id: String, status: RunStatus)

    /// The workspace directory for the run no longer exists on disk.
    case workspaceNotFound(runID: String)

    /// A node that was completed in a previous run no longer exists in the
    /// updated workflow definition, making resume unsafe.
    case completedNodeRemoved(nodeID: String)

    /// Attempted to respond to a node that is not in awaiting_input status.
    case nodeNotAwaitingInput(nodeID: String, status: NodeStatus)

    /// The named evaluator could not be found (neither built-in nor custom).
    case evaluatorNotFound(name: String)

    /// The evaluator threw an error during execution.
    case evaluatorFailed(name: String, detail: String)

    /// A loop node exceeded its configured max_iterations without the
    /// evaluator returning true.
    case maxIterationsReached(nodeID: String, count: Int)

    /// A node's upstream dependency failed, preventing execution.
    case dependencyFailed(nodeID: String, upstream: String)

    /// The workflow DAG contains a cycle, preventing topological ordering.
    case cyclicDependency(nodes: [String])

    /// A nested (child) workflow referenced by a node failed during execution.
    case nestedWorkflowFailed(nodeID: String, workflowFile: String, detail: String)

    /// Attempted to initialize a project where `.orc/` already exists.
    case projectAlreadyExists(path: String)

    /// A required workflow input was not provided and has no default value.
    case missingRequiredInput(name: String, workflow: String)

    /// A node config field resolved to an invalid value.
    case invalidConfigValue(node: String, field: String, value: String, expected: String)

    /// A node's streaming execution completed without producing output.
    case nodeExecutionFailed(nodeID: String, detail: String)

}

extension EngineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .workflowAlreadyRunning(let id):
            "Workflow '\(id)' is already running."
        case .runNotFound(let id):
            "Run '\(id)' not found."
        case .runNotResumable(let id, let status):
            "Run '\(id)' cannot be resumed (status: \(status.rawValue))."
        case .workspaceNotFound(let runID):
            "Workspace not found for run '\(runID)'."
        case .completedNodeRemoved(let nodeID):
            "Completed node '\(nodeID)' was removed from the workflow."
        case .nodeNotAwaitingInput(let nodeID, let status):
            "Node '\(nodeID)' is not awaiting input (status: \(status.rawValue))."
        case .evaluatorNotFound(let name):
            "Evaluator '\(name)' not found."
        case .evaluatorFailed(let name, let detail):
            "Evaluator '\(name)' failed: \(detail)"
        case .maxIterationsReached(let nodeID, let count):
            "Node '\(nodeID)' reached max iterations (\(count))."
        case .dependencyFailed(let nodeID, let upstream):
            "Node '\(nodeID)' skipped: dependency '\(upstream)' failed."
        case .cyclicDependency(let nodes):
            "Cyclic dependency detected among nodes: \(nodes.joined(separator: ", "))"
        case .nestedWorkflowFailed(let nodeID, let workflowFile, let detail):
            "Node '\(nodeID)' nested workflow '\(workflowFile)' failed: \(detail)"
        case .projectAlreadyExists(let path):
            "Orc already initialized (\(path))."
        case .missingRequiredInput(let name, let workflow):
            "Missing required input '\(name)' for workflow '\(workflow)'."
        case .invalidConfigValue(let node, let field, let value, let expected):
            "[\(node)] Config field '\(field)' resolved to '\(value)'; expected \(expected)."
        case .nodeExecutionFailed(let nodeID, let detail):
            "Node '\(nodeID)' execution failed: \(detail)"
        }
    }
}

extension EngineError: LocalizedError {
    public var errorDescription: String? { description }
}
