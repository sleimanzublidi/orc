// MARK: - ProviderError

/// Typed errors for the Providers module, covering subprocess failures,
/// timeouts, tmux issues, output parsing problems, and missing providers.
public enum ProviderError: Error, Sendable, Equatable {
    /// A subprocess exited with a non-zero code.
    case processFailure(command: String, exitCode: Int32, stderr: String)

    /// A subprocess exceeded its allowed execution time.
    case timeout(command: String, seconds: Int)

    /// A tmux operation failed (create, destroy, capture).
    case tmuxFailure(session: String, detail: String)

    /// Agent output could not be parsed into the expected format.
    case outputParseFailure(provider: String, detail: String)

    /// No registered provider matches the requested name.
    case providerNotFound(name: String)
}

extension ProviderError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .processFailure(let command, let exitCode, let stderr):
            return "Process '\(command)' exited with code \(exitCode): \(stderr)"
        case .timeout(let command, let seconds):
            return "Process '\(command)' timed out after \(seconds)s."
        case .tmuxFailure(let session, let detail):
            return "Tmux session '\(session)' failed: \(detail)"
        case .outputParseFailure(let provider, let detail):
            return "Failed to parse output from '\(provider)': \(detail)"
        case .providerNotFound(let name):
            return "Provider '\(name)' not found."
        }
    }
}
