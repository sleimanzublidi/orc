// MARK: - CatalogEntry

/// A single item discovered in the .orc/ directory (workflow or evaluator).
public struct CatalogEntry: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let fileName: String

    public init(name: String, description: String?, fileName: String) {
        self.name = name
        self.description = description
        self.fileName = fileName
    }
}

// MARK: - Catalog

/// The full set of artifacts available in an initialized .orc/ project.
public struct Catalog: Sendable, Equatable {
    public let workflows: [CatalogEntry]
    public let evaluators: [CatalogEntry]

    public init(workflows: [CatalogEntry], evaluators: [CatalogEntry]) {
        self.workflows = workflows
        self.evaluators = evaluators
    }
}
