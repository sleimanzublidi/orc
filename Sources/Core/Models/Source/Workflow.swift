// MARK: - Workflow

/// A complete workflow definition parsed from YAML.
/// Contains the DAG of nodes, inputs, and optional output mappings.
public struct Workflow: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let input: [WorkflowInput]
    public let nodes: [Node]
    public let output: [String: String]?
    public let cleanupPolicy: CleanupPolicy

    public init(
        name: String,
        description: String? = nil,
        input: [WorkflowInput] = [],
        nodes: [Node] = [],
        output: [String: String]? = nil,
        cleanupPolicy: CleanupPolicy = .duration(days: 30)
    ) {
        self.name = name
        self.description = description
        self.input = input
        self.nodes = nodes
        self.output = output
        self.cleanupPolicy = cleanupPolicy
    }
}

// MARK: - WorkflowInput

/// A declared input parameter for a workflow.
public struct WorkflowInput: Sendable, Equatable, Codable {
    public let name: String
    public let type: String
    public let required: Bool

    public init(
        name: String,
        type: String = "string",
        required: Bool = true
    ) {
        self.name = name
        self.type = type
        self.required = required
    }
}
