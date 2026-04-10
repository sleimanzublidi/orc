// MARK: - ValidationError

/// A single validation issue found during workflow parsing or pre-flight checks.
public struct ValidationError: Sendable, Equatable, Codable {
    public let message: String
    public let nodeID: String?

    public init(
        message: String,
        nodeID: String? = nil
    ) {
        self.message = message
        self.nodeID = nodeID
    }
}

// MARK: - ValidationResult

/// The outcome of validating a parsed workflow.
public struct ValidationResult: Sendable, Equatable, Codable {
    public let errors: [ValidationError]
    public let warnings: [ValidationError]

    /// A workflow is valid when it contains no errors.
    public var isValid: Bool { errors.isEmpty }

    public init(
        errors: [ValidationError] = [],
        warnings: [ValidationError] = []
    ) {
        self.errors = errors
        self.warnings = warnings
    }
}
