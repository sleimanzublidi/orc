import Models

/// The result of planning a workflow execution: nodes in topological order,
/// lookup tables by ID, and a reverse-dependency map for dispatching.
struct ExecutionPlan: Sendable {
    /// The original workflow definition.
    let workflow: Workflow

    /// Node IDs in topological order (dependencies come before dependents).
    let topologicalOrder: [String]

    /// Fast lookup from node ID to node definition.
    let nodesByID: [String: Models.Node]

    /// Reverse dependency map: for each node, which nodes depend on it.
    /// Used to determine which nodes become ready after one completes.
    let dependents: [String: [String]]
}
