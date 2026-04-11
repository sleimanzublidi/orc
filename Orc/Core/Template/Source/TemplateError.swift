import Foundation

/// Errors raised during template resolution and expression evaluation.
public enum TemplateError: Error, Sendable, Equatable {
    /// A `{{variable}}` reference could not be resolved from the task context.
    case unresolvedVariable(name: String)

    /// The template string is syntactically invalid (e.g., unclosed `{{`).
    case malformedTemplate(detail: String)

    /// A `when:` expression has invalid syntax (e.g., missing operand).
    case expressionSyntax(detail: String)

    /// A `when:` expression could not be evaluated to a boolean result.
    case expressionEvaluation(detail: String)
}

extension TemplateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unresolvedVariable(let name):
            return "Unresolved variable '{{\(name)}}'."
        case .malformedTemplate(let detail):
            return "Malformed template: \(detail)"
        case .expressionSyntax(let detail):
            return "Expression syntax error: \(detail)"
        case .expressionEvaluation(let detail):
            return "Expression evaluation error: \(detail)"
        }
    }
}

extension TemplateError: LocalizedError {
    public var errorDescription: String? { description }
}
