// MARK: - EvaluatorType

/// The kind of evaluator used to assess loop/conditional outcomes.
public enum EvaluatorType: String, Sendable, Equatable, Codable {
    case ai
    case script
    case workflow
}

// MARK: - EvaluatorDefinition

/// A named evaluator that can be referenced in loop `until` or `when` expressions.
public struct EvaluatorDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let type: EvaluatorType
    public let agent: String?
    public let prompt: String?
    public let command: String?

    public init(
        name: String,
        type: EvaluatorType,
        agent: String? = nil,
        prompt: String? = nil,
        command: String? = nil
    ) {
        self.name = name
        self.type = type
        self.agent = agent
        self.prompt = prompt
        self.command = command
    }
}
