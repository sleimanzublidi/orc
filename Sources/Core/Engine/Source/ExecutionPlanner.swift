import Models

/// Builds an execution plan from a Workflow by computing topological order
/// and constructing lookup tables needed for dispatch.
///
/// Uses Kahn's algorithm (BFS-based topological sort) to produce a valid
/// execution order. This is re-implemented here because the Parser module's
/// DAGValidator is internal to that module.
struct ExecutionPlanner: Sendable {

    /// Creates an execution plan from a workflow.
    ///
    /// - Parameter workflow: A validated workflow whose DAG is cycle-free.
    /// - Returns: An `ExecutionPlan` with nodes in topological order.
    /// - Throws: `EngineError` if a cycle is detected (should not happen
    ///   after parser validation, but enforced as a safety net).
    func plan(workflow: Workflow) throws -> ExecutionPlan {
        let topOrder = try topologicalSort(nodes: workflow.nodes)

        var nodesByID: [String: Models.Node] = [:]
        for node in workflow.nodes {
            nodesByID[node.id] = node
        }

        // Build reverse dependency map: for each node, which nodes depend on it.
        var dependents: [String: [String]] = [:]
        for node in workflow.nodes {
            for dep in node.dependsOn {
                dependents[dep, default: []].append(node.id)
            }
        }

        return ExecutionPlan(
            workflow: workflow,
            topologicalOrder: topOrder,
            nodesByID: nodesByID,
            dependents: dependents
        )
    }

    // MARK: - Topological Sort (Kahn's Algorithm)

    /// Returns node IDs in topological order using Kahn's algorithm.
    /// Deterministic: ties are broken alphabetically.
    private func topologicalSort(nodes: [Models.Node]) throws -> [String] {
        let nodeIDs = Set(nodes.map(\.id))

        // Build in-degree map. An edge from dep -> node means "dep must run before node".
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        for id in nodeIDs {
            inDegree[id] = 0
            adjacency[id] = []
        }

        for node in nodes {
            for dep in node.dependsOn where nodeIDs.contains(dep) {
                adjacency[dep, default: []].append(node.id)
                inDegree[node.id, default: 0] += 1
            }
        }

        // Start with zero-in-degree nodes, sorted for determinism.
        var queue = nodeIDs.sorted().filter { inDegree[$0, default: 0] == 0 }
        var sorted: [String] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            sorted.append(current)

            for neighbor in adjacency[current, default: []] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor, default: 0] == 0 {
                    // Insert in sorted position for determinism.
                    let insertIndex = queue.firstIndex(where: { $0 > neighbor }) ?? queue.endIndex
                    queue.insert(neighbor, at: insertIndex)
                }
            }
        }

        if sorted.count != nodeIDs.count {
            // Cycle detected — gather the remaining nodes for the error.
            let remaining = nodeIDs.subtracting(sorted)
            // Report first remaining node alphabetically for determinism.
            let cycle = remaining.sorted()
            throw EngineError.cyclicDependency(nodes: cycle)
        }

        return sorted
    }
}
