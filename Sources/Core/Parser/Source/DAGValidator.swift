import Models

/// Internal helper that validates the directed acyclic graph (DAG) structure
/// of a workflow's node dependencies.
///
/// Uses Kahn's algorithm (BFS-based topological sort) to detect cycles
/// and produce a valid execution order.
struct DAGValidator {

    /// Returns a topological ordering of node IDs.
    ///
    /// - Parameter nodes: The workflow nodes whose `dependsOn` edges define the DAG.
    /// - Returns: An array of node IDs in valid execution order (dependencies before dependents).
    /// - Throws: `ParserError.circularDependency` if a cycle exists.
    static func topologicalSort(nodes: [Models.Node]) throws -> [String] {
        let nodeIDs = Set(nodes.map(\.id))

        // Build adjacency list and in-degree map.
        // An edge from A to B means "A must run before B" (B depends on A).
        var adjacency: [String: [String]] = [:]
        var inDegree: [String: Int] = [:]

        for id in nodeIDs {
            adjacency[id] = []
            inDegree[id] = 0
        }

        for node in nodes {
            for dep in node.dependsOn {
                // Only consider edges to known nodes; missing-reference
                // validation is handled separately.
                guard nodeIDs.contains(dep) else { continue }
                adjacency[dep, default: []].append(node.id)
                inDegree[node.id, default: 0] += 1
            }
        }

        // Kahn's algorithm: start with zero-in-degree nodes.
        var queue = nodeIDs.sorted().filter { inDegree[$0, default: 0] == 0 }
        var sorted: [String] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            sorted.append(current)

            for neighbor in adjacency[current, default: []] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor, default: 0] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        // If not all nodes were visited, a cycle exists.
        if sorted.count != nodeIDs.count {
            let cycle = findCycle(nodes: nodes, remaining: nodeIDs.subtracting(sorted))
            throw ParserError.circularDependency(cycle: cycle)
        }

        return sorted
    }

    // MARK: - Cycle Detection (DFS)

    /// Finds a cycle among the unvisited nodes using DFS and returns the node IDs
    /// that form the loop.
    ///
    /// Called only when Kahn's algorithm fails to process all nodes.
    private static func findCycle(nodes: [Models.Node], remaining: Set<String>) -> [String] {
        let dependsMap: [String: [String]] = {
            var map: [String: [String]] = [:]
            for node in nodes where remaining.contains(node.id) {
                map[node.id] = node.dependsOn.filter { remaining.contains($0) }
            }
            return map
        }()

        var visited = Set<String>()
        var onStack = Set<String>()
        var parent: [String: String] = [:]

        for startID in remaining.sorted() {
            if visited.contains(startID) { continue }

            // Iterative DFS using an explicit stack.
            // Each frame is (nodeID, isBacktrack).
            var stack: [(String, Bool)] = [(startID, false)]

            while !stack.isEmpty {
                let (nodeID, isBacktrack) = stack.removeLast()

                if isBacktrack {
                    onStack.remove(nodeID)
                    continue
                }

                if onStack.contains(nodeID) {
                    // Found a cycle — trace back through parent links.
                    return traceCycle(from: nodeID, parent: parent)
                }

                if visited.contains(nodeID) { continue }

                visited.insert(nodeID)
                onStack.insert(nodeID)
                // Push backtrack marker so we remove from onStack when done.
                stack.append((nodeID, true))

                for dep in dependsMap[nodeID, default: []] {
                    if onStack.contains(dep) {
                        // dep is already on the current path — cycle detected.
                        parent[dep] = nodeID
                        return traceCycle(from: dep, parent: parent)
                    }
                    if !visited.contains(dep) {
                        parent[dep] = nodeID
                        stack.append((dep, false))
                    }
                }
            }
        }

        // Fallback: return remaining node IDs sorted (should not happen in practice).
        return remaining.sorted()
    }

    /// Traces back through the parent map to reconstruct the cycle path.
    private static func traceCycle(from start: String, parent: [String: String]) -> [String] {
        var cycle = [start]
        var current = start

        while let prev = parent[current] {
            cycle.append(prev)
            if prev == start { break }
            current = prev
        }

        return cycle.reversed()
    }
}
