import Testing
import Foundation
import Models
import Providers
@testable import Engine

/// Tests for ConfigManager parsing and provider loading from `.orc/config.yml`.
struct ConfigManagerTests {

    // MARK: - Helpers

    /// Creates a temporary `.orc` directory with an optional `config.yml` file.
    /// Returns the path to the `.orc` directory.
    private func makeTempOrcDir(configYAML: String? = nil) throws -> String {
        let tmpDir = NSTemporaryDirectory() + "orc-config-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        if let yaml = configYAML {
            let configPath = (tmpDir as NSString).appendingPathComponent("config.yml")
            try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
        }

        return tmpDir
    }

    // MARK: - Default Config (No File)

    @Test("loadConfig returns defaults when no config file exists")
    func loadConfigDefaults() throws {
        let dir = try makeTempOrcDir()
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config.maxParallelNodes == ProcessInfo.processInfo.processorCount)
        #expect(config.retentionDays == 30)
        #expect(config.retentionPolicy == "completed_only")
        #expect(config.defaultShell == Platform.defaultShell)
        #expect(config.providers.isEmpty)
    }

    @Test("Default providers are always present when no config exists")
    func defaultProvidersWithNoConfig() throws {
        let config = OrcConfig.default
        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        // Both shell and claude-code should be available by default.
        let shell = try registry.provider(named: "shell")
        #expect(shell.name == "shell")

        let claude = try registry.provider(named: "claude-code")
        #expect(claude.name == "claude-code")
    }

    // MARK: - Providers Section Parsing

    @Test("Parses providers section with cli-agent type")
    func parsesCliAgentProviders() throws {
        let yaml = """
        providers:
          codex:
            type: cli-agent
            command: "codex -q '{{prompt}}'"
            interactive_command: "codex"
          aider:
            type: cli-agent
            command: "aider --message '{{prompt}}'"
            interactive_command: "aider"
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config.providers.count == 2)

        let codex = config.providers["codex"]
        #expect(codex != nil)
        #expect(codex?.type == "cli-agent")
        #expect(codex?.command == "codex -q '{{prompt}}'")
        #expect(codex?.interactiveCommand == "codex")

        let aider = config.providers["aider"]
        #expect(aider != nil)
        #expect(aider?.type == "cli-agent")
        #expect(aider?.command == "aider --message '{{prompt}}'")
        #expect(aider?.interactiveCommand == "aider")
    }

    @Test("Parses claude-code provider with custom path")
    func parsesClaudeCodeProvider() throws {
        let yaml = """
        providers:
          claude-code:
            path: /opt/homebrew/bin/claude
            default_model: opus
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        let claude = config.providers["claude-code"]
        #expect(claude != nil)
        #expect(claude?.path == "/opt/homebrew/bin/claude")
        #expect(claude?.defaultModel == "opus")
    }

    @Test("Parses shell provider with custom default_shell")
    func parsesShellProvider() throws {
        let yaml = """
        providers:
          shell:
            default_shell: /bin/bash
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        let shell = config.providers["shell"]
        #expect(shell != nil)
        #expect(shell?.defaultShell == "/bin/bash")
        // The top-level defaultShell should also be updated.
        #expect(config.defaultShell == "/bin/bash")
    }

    @Test("Parses full config with all sections")
    func parsesFullConfig() throws {
        let yaml = """
        providers:
          claude-code:
            path: /usr/local/bin/claude
            default_model: opus
          codex:
            type: cli-agent
            command: "codex -q '{{prompt}}'"
            interactive_command: "codex"
          shell:
            default_shell: /bin/bash
        concurrency:
          max_parallel_nodes: 4
        storage:
          retention_days: 30
          retention_policy: completed_only
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config.maxParallelNodes == 4)
        #expect(config.retentionDays == 30)
        #expect(config.retentionPolicy == "completed_only")
        #expect(config.providers.count == 3)
        #expect(config.providers["codex"]?.type == "cli-agent")
    }

    // MARK: - Provider Registry Construction

    @Test("buildProviderRegistry creates CLIAgentProvider from cli-agent config")
    func buildRegistryWithCliAgent() throws {
        var config = OrcConfig.default
        config.providers["codex"] = ProviderConfig(
            type: "cli-agent",
            command: "codex -q '{{prompt}}'",
            interactiveCommand: "codex"
        )

        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        // Should have shell, claude-code (defaults), and codex.
        let codex = try registry.provider(named: "codex")
        #expect(codex.name == "codex")

        let shell = try registry.provider(named: "shell")
        #expect(shell.name == "shell")

        let claude = try registry.provider(named: "claude-code")
        #expect(claude.name == "claude-code")
    }

    @Test("buildProviderRegistry overrides claude-code path from config")
    func buildRegistryOverridesClaudePath() throws {
        var config = OrcConfig.default
        config.providers["claude-code"] = ProviderConfig(
            path: "/opt/homebrew/bin/claude"
        )

        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        // Should still resolve claude-code (with custom path).
        let claude = try registry.provider(named: "claude-code")
        #expect(claude.name == "claude-code")

        // Default shell should still be present.
        let shell = try registry.provider(named: "shell")
        #expect(shell.name == "shell")
    }

    @Test("buildProviderRegistry overrides shell default_shell from config")
    func buildRegistryOverridesShell() throws {
        var config = OrcConfig.default
        config.providers["shell"] = ProviderConfig(defaultShell: "/bin/bash")

        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        let shell = try registry.provider(named: "shell")
        #expect(shell.name == "shell")
    }

    @Test("buildProviderRegistry ignores cli-agent without command")
    func buildRegistryIgnoresCliAgentWithoutCommand() throws {
        var config = OrcConfig.default
        config.providers["broken"] = ProviderConfig(type: "cli-agent")

        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        // "broken" should not be registered because it has no command.
        #expect(throws: ProviderError.self) {
            _ = try registry.provider(named: "broken")
        }
    }

    @Test("buildProviderRegistry creates multiple CLI agents")
    func buildRegistryMultipleCliAgents() throws {
        var config = OrcConfig.default
        config.providers["codex"] = ProviderConfig(
            type: "cli-agent",
            command: "codex -q '{{prompt}}'",
            interactiveCommand: "codex"
        )
        config.providers["aider"] = ProviderConfig(
            type: "cli-agent",
            command: "aider --message '{{prompt}}'",
            interactiveCommand: "aider"
        )

        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        let codex = try registry.provider(named: "codex")
        #expect(codex.name == "codex")

        let aider = try registry.provider(named: "aider")
        #expect(aider.name == "aider")
    }

    // MARK: - Backward Compatibility

    @Test("Flat YAML keys still work for backward compatibility")
    func flatKeysBackwardCompatibility() throws {
        let yaml = """
        max_parallel_nodes: 8
        retention_days: 60
        retention_policy: all
        default_shell: /bin/bash
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config.maxParallelNodes == 8)
        #expect(config.retentionDays == 60)
        #expect(config.retentionPolicy == "all")
        #expect(config.defaultShell == "/bin/bash")
    }

    @Test("Empty config file returns defaults")
    func emptyConfigReturnsDefaults() throws {
        let dir = try makeTempOrcDir(configYAML: "")
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config == OrcConfig.default)
    }

    // MARK: - setValue Tests

    @Test("setValue sets a top-level key")
    func setValueTopLevelKey() throws {
        let dir = try makeTempOrcDir()
        let manager = ConfigManager(basePath: dir)

        try manager.setValue(key: "max_parallel_nodes", value: "8")

        let config = try manager.loadConfig()
        #expect(config.maxParallelNodes == 8)
    }

    @Test("setValue sets a nested dot-notation key")
    func setValueNestedKey() throws {
        let dir = try makeTempOrcDir()
        let manager = ConfigManager(basePath: dir)

        try manager.setValue(key: "concurrency.max_parallel_nodes", value: "6")

        let config = try manager.loadConfig()
        #expect(config.maxParallelNodes == 6)
    }

    @Test("setValue creates intermediate dictionaries when they don't exist")
    func setValueCreatesIntermediateDicts() throws {
        let dir = try makeTempOrcDir()
        let manager = ConfigManager(basePath: dir)

        // No config file exists yet; setValue should create one with nested structure.
        try manager.setValue(key: "storage.retention_days", value: "90")

        let config = try manager.loadConfig()
        #expect(config.retentionDays == 90)
    }

    @Test("setValue overwrites an existing value")
    func setValueOverwritesExisting() throws {
        let yaml = """
        concurrency:
          max_parallel_nodes: 4
        """
        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)

        // Verify initial value.
        let before = try manager.loadConfig()
        #expect(before.maxParallelNodes == 4)

        // Overwrite with a new value.
        try manager.setValue(key: "concurrency.max_parallel_nodes", value: "16")

        let after = try manager.loadConfig()
        #expect(after.maxParallelNodes == 16)
    }

    // MARK: - unsetValue Tests

    @Test("unsetValue removes a top-level key")
    func unsetValueTopLevelKey() throws {
        let yaml = """
        max_parallel_nodes: 8
        retention_days: 60
        """
        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)

        // Verify the key exists before removal.
        let before = try manager.loadConfig()
        #expect(before.maxParallelNodes == 8)

        try manager.unsetValue(key: "max_parallel_nodes")

        // After removal, the key falls back to the default value.
        let after = try manager.loadConfig()
        #expect(after.maxParallelNodes == ProcessInfo.processInfo.processorCount)
        // The other key should remain.
        #expect(after.retentionDays == 60)
    }

    // MARK: - Verbose Config

    @Test("Parses output.verbose from config")
    func parsesOutputVerbose() throws {
        let yaml = """
        output:
          verbose: true
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config.verbose == true)
    }

    @Test("Default config has verbose false")
    func defaultConfigVerboseFalse() throws {
        let dir = try makeTempOrcDir()
        let manager = ConfigManager(basePath: dir)
        let config = try manager.loadConfig()

        #expect(config.verbose == false)
    }

    @Test("getValue resolves output.verbose key")
    func getValueOutputVerbose() throws {
        let yaml = """
        output:
          verbose: true
        """

        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)
        let value = try manager.getValue(key: "output.verbose")

        #expect(value == "true")
    }

    @Test("unsetValue removes a nested key and cleans up empty parent")
    func unsetValueNestedKeyWithCleanup() throws {
        let yaml = """
        concurrency:
          max_parallel_nodes: 4
        """
        let dir = try makeTempOrcDir(configYAML: yaml)
        let manager = ConfigManager(basePath: dir)

        try manager.unsetValue(key: "concurrency.max_parallel_nodes")

        // The nested key was the only child of "concurrency", so the parent
        // should also be removed, yielding a config equal to defaults.
        let after = try manager.loadConfig()
        #expect(after.maxParallelNodes == ProcessInfo.processInfo.processorCount)
    }
}
