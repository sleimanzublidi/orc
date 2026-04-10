import Models

// MARK: - ProviderRegistry

/// Resolves agent names to their concrete `AgentProviding` implementations.
/// Providers are registered at initialization and looked up by name at runtime.
public struct ProviderRegistry: Sendable {
    private let providers: [String: any AgentProviding]

    public init(providers: [any AgentProviding] = []) {
        var dict: [String: any AgentProviding] = [:]
        for provider in providers {
            dict[provider.name] = provider
        }
        self.providers = dict
    }

    /// Returns the provider registered under the given name.
    /// Throws `ProviderError.providerNotFound` if no match exists.
    public func provider(named name: String) throws -> any AgentProviding {
        guard let p = providers[name] else {
            throw ProviderError.providerNotFound(name: name)
        }
        return p
    }
}

// MARK: - Factory

/// Factory for creating concrete provider instances.
///
/// The concrete types (`ClaudeCodeProvider`, `ShellProvider`, `CLIAgentProvider`,
/// `ProcessRunner`, `TmuxSession`) are `internal`; callers across module
/// boundaries access them through this factory and the corresponding protocols.
public enum ProviderFactory {
    public static func makeClaudeCode(
        claudePath: String = "/usr/local/bin/claude"
    ) -> any AgentProviding {
        ClaudeCodeProvider(claudePath: claudePath)
    }

    public static func makeShell(
        defaultShell: String = "/bin/zsh"
    ) -> any AgentProviding {
        ShellProvider(defaultShell: defaultShell)
    }

    public static func makeCLIAgent(
        name: String,
        commandTemplate: String,
        interactiveCommand: String? = nil
    ) -> any AgentProviding {
        CLIAgentProvider(
            name: name,
            commandTemplate: commandTemplate,
            interactiveCommand: interactiveCommand
        )
    }

    public static func makeProcessRunner() -> any ProcessRunning {
        ProcessRunner()
    }

    public static func makeTmuxSession() -> any TmuxProviding {
        TmuxSession()
    }
}
