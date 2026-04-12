import Foundation
import Models

/// Errors raised during YAML workflow parsing and structural validation.
///
/// Each case carries enough context to produce a useful diagnostic message
/// (e.g., which node or field caused the failure).
public enum ParserError: Error, Sendable, Equatable {
    /// The YAML string could not be deserialized.
    case yamlSyntax(detail: String)

    /// A required field is missing from the YAML definition.
    /// `node` is nil for top-level fields.
    case missingField(node: String?, field: String)

    /// Two or more nodes share the same `id`.
    case duplicateNodeID(id: String)

    /// The dependency graph contains a cycle.
    /// `cycle` lists the node IDs that form the loop.
    case circularDependency(cycle: [String])

    /// A `depends_on` entry references a node ID that does not exist.
    case invalidReference(node: String, ref: String)

    /// A `when:` expression or template variable has invalid syntax.
    case invalidExpression(node: String, detail: String)

    /// A field value has the wrong type (e.g., an integer where a string was expected).
    case invalidFieldType(node: String, field: String, expected: String)

    /// Structural validation produced one or more errors.
    case validation(errors: [ValidationError])
}

extension ParserError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .yamlSyntax(let detail):
            return "YAML syntax error: \(detail)"
        case .missingField(let node, let field):
            let prefix = node.map { "[\($0)] " } ?? ""
            return "\(prefix)Missing required field '\(field)'"
        case .duplicateNodeID(let id):
            return "Duplicate node ID '\(id)'"
        case .circularDependency(let cycle):
            return "Circular dependency: \(cycle.joined(separator: " -> "))"
        case .invalidReference(let node, let ref):
            return "[\(node)] Invalid reference to '\(ref)'"
        case .invalidExpression(let node, let detail):
            return "[\(node)] Invalid expression: \(detail)"
        case .invalidFieldType(let node, let field, let expected):
            return "[\(node)] Field '\(field)' has invalid type; expected \(expected)"
        case .validation(let errors):
            // Indent all error lines consistently with a 2-space prefix.
            return errors.map { err in
                let prefix = err.nodeID.map { "[\($0)] " } ?? ""
                return "  \(prefix)\(err.message)"
            }.joined(separator: "\n")
        }
    }
}

extension ParserError: LocalizedError {
    public var errorDescription: String? { description }
}
