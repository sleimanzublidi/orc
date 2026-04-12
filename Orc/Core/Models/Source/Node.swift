// MARK: - Node

/// A single step in a workflow DAG. Represents either an agent invocation,
/// a shell command, or a sub-workflow reference.
///
/// Several configuration fields use `Resolvable<T>` to support both static
/// literals and `{{…}}` template expressions that are resolved at runtime.
public struct Node: Sendable, Equatable, Codable {
    public let id: String
    public let agent: Resolvable<String>?
    public let prompt: String?
    public let promptFile: String?
    public let command: String?
    public let dependsOn: [String]
    public let output: String?
    public let when: String?
    public let loop: LoopConfig?
    public let interactive: InteractiveMode?
    public let retry: RetryConfig?
    public let timeoutSeconds: Resolvable<Int>?
    public let onFailure: Resolvable<FailureStrategy>
    public let workflow: String?
    public let inputs: [String: String]?
    public let workspaceMode: Resolvable<WorkspaceMode>?
    public let parameters: [String: Resolvable<String>]

    public init(
        id: String,
        agent: Resolvable<String>? = nil,
        prompt: String? = nil,
        promptFile: String? = nil,
        command: String? = nil,
        dependsOn: [String] = [],
        output: String? = nil,
        when: String? = nil,
        loop: LoopConfig? = nil,
        interactive: InteractiveMode? = nil,
        retry: RetryConfig? = nil,
        timeoutSeconds: Resolvable<Int>? = nil,
        onFailure: Resolvable<FailureStrategy> = .literal(.stop),
        workflow: String? = nil,
        inputs: [String: String]? = nil,
        workspaceMode: Resolvable<WorkspaceMode>? = nil,
        parameters: [String: Resolvable<String>] = [:]
    ) {
        self.id = id
        self.agent = agent
        self.prompt = prompt
        self.promptFile = promptFile
        self.command = command
        self.dependsOn = dependsOn
        self.output = output
        self.when = when
        self.loop = loop
        self.interactive = interactive
        self.retry = retry
        self.timeoutSeconds = timeoutSeconds
        self.onFailure = onFailure
        self.workflow = workflow
        self.inputs = inputs
        self.workspaceMode = workspaceMode
        self.parameters = parameters
    }
}

// MARK: - InteractiveMode

/// How a node interacts with the user during execution.
/// - `.session`: long-lived tmux session
/// - `.prompt(message:)`: one-shot prompt with a custom message
public enum InteractiveMode: Sendable, Equatable {
    case session
    case prompt(message: String)
}

extension InteractiveMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case prompt
    }

    public init(from decoder: Decoder) throws {
        // Try decoding as a plain string first ("session")
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            guard value == "session" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown InteractiveMode string: \(value)"
                )
            }
            self = .session
            return
        }

        // Otherwise decode as {"prompt": "message text"}
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .prompt)
        self = .prompt(message: message)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .session:
            var container = encoder.singleValueContainer()
            try container.encode("session")
        case .prompt(let message):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .prompt)
        }
    }
}

// MARK: - LoopConfig

/// Configuration for nodes that repeat until a condition is met.
public struct LoopConfig: Sendable, Equatable, Codable {
    public let until: String
    public let maxIterations: Resolvable<Int>
    public let freshContext: Resolvable<Bool>

    public init(
        until: String,
        maxIterations: Resolvable<Int> = .literal(10),
        freshContext: Resolvable<Bool> = .literal(false)
    ) {
        self.until = until
        self.maxIterations = maxIterations
        self.freshContext = freshContext
    }
}

// MARK: - RetryConfig

/// Configuration for automatic retry on node failure.
public struct RetryConfig: Sendable, Equatable, Codable {
    public let maxAttempts: Resolvable<Int>
    public let delaySeconds: Resolvable<Int>

    public init(
        maxAttempts: Resolvable<Int> = .literal(1),
        delaySeconds: Resolvable<Int> = .literal(0)
    ) {
        self.maxAttempts = maxAttempts
        self.delaySeconds = delaySeconds
    }
}

// MARK: - FailureStrategy

/// What happens when a node fails.
public enum FailureStrategy: String, Sendable, Equatable, Codable {
    case stop
    case skip
    case `continue`
}

// MARK: - WorkspaceMode

/// Whether a node shares the run workspace or gets its own isolated copy.
public enum WorkspaceMode: String, Sendable, Equatable, Codable {
    case shared
    case isolated
}

