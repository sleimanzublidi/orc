import Foundation
import Logging
import Models
import Yams

/// Loads and manages the `.orc/config.yml` configuration file.
///
/// Supports dot-notation key access (e.g., `concurrency.max_parallel_nodes`),
/// reading/writing individual values, and merging with defaults.
///
/// Merge precedence: CLI flags > workflow YAML > config.yml > defaults
public struct ConfigManager: Sendable {
    /// Path to the `.orc` directory.
    let basePath: String

    private let logger = Logger(label: "orc.engine.config")

    public init(basePath: String) {
        self.basePath = basePath
    }

    /// Loads configuration from `.orc/config.yml`, merging with defaults.
    ///
    /// - Returns: A fully populated `OrcConfig`.
    public func loadConfig() throws -> OrcConfig {
        let configPath = (basePath as NSString).appendingPathComponent("config.yml")
        let fm = FileManager.default

        guard fm.fileExists(atPath: configPath),
              let data = fm.contents(atPath: configPath),
              let contents = String(data: data, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return OrcConfig.default
        }

        return parseConfig(from: contents)
    }

    /// Gets a configuration value by dot-notation key.
    ///
    /// - Parameter key: The dot-notation key (e.g., "concurrency.max_parallel_nodes").
    /// - Returns: The string value, or nil if not set.
    func getValue(key: String) throws -> String? {
        let config = try loadConfig()
        return resolveKey(key, in: config)
    }

    /// Sets a configuration value by dot-notation key.
    ///
    /// Uses Yams to load the existing config as a nested dictionary, sets the
    /// value at the correct nesting level (e.g., `concurrency.max_parallel_nodes`
    /// sets `concurrency: { max_parallel_nodes: value }`), and writes back.
    ///
    /// - Parameters:
    ///   - key: The dot-notation key.
    ///   - value: The value to set.
    func setValue(key: String, value: String) throws {
        let configPath = (basePath as NSString).appendingPathComponent("config.yml")

        // Load existing YAML as a nested dictionary, or start empty.
        var dict = loadYAMLDictionary(at: configPath)

        // Split on "." to support nested keys (e.g., "concurrency.max_parallel_nodes").
        let components = key.split(separator: ".").map(String.init)

        if components.count == 1 {
            // Top-level key.
            dict[components[0]] = autoTypedValue(value)
        } else {
            // Nested key: walk/create intermediate dictionaries.
            var current = dict
            for (index, component) in components.dropLast().enumerated() {
                if let existing = current[component] as? [String: Any] {
                    current = existing
                } else {
                    // Build the nested value from the inside out.
                    var nested: Any = autoTypedValue(value)
                    for innerComponent in components.suffix(from: index + 1).reversed() {
                        nested = [String(innerComponent): nested]
                    }
                    // Merge the constructed nested dict into the top-level dict.
                    setNestedValue(in: &dict, keys: Array(components.prefix(index)) + [component], value: nested)
                    let serialized = try serializeYAML(dict)
                    try serialized.write(toFile: configPath, atomically: true, encoding: .utf8)
                    return
                }
            }
            // All intermediate dicts existed — set the leaf value.
            setNestedValue(in: &dict, keys: components.dropLast().map { $0 }, value: [components.last!: autoTypedValue(value)])
        }

        let serialized = try serializeYAML(dict)
        try serialized.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Removes a configuration value by dot-notation key.
    ///
    /// - Parameter key: The dot-notation key to remove.
    func unsetValue(key: String) throws {
        let configPath = (basePath as NSString).appendingPathComponent("config.yml")
        var dict = loadYAMLDictionary(at: configPath)

        let components = key.split(separator: ".").map(String.init)

        if components.count == 1 {
            dict.removeValue(forKey: components[0])
        } else {
            // Walk to the parent dict and remove the leaf key.
            removeNestedValue(from: &dict, keys: components)
        }

        let serialized = try serializeYAML(dict)
        try serialized.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Helpers

    /// Parses the config YAML using Yams to handle nested sections like `providers:`.
    ///
    /// The YAML structure supports both flat keys and nested sections:
    /// - `concurrency.max_parallel_nodes` (nested under `concurrency:`)
    /// - `storage.retention_days` / `storage.retention_policy` (nested under `storage:`)
    /// - `providers:` section with per-provider configuration dictionaries
    private func parseConfig(from yaml: String) -> OrcConfig {
        // Attempt structured Yams parsing for nested YAML support.
        let parsed: [String: Any]
        do {
            guard let result = try Yams.load(yaml: yaml) as? [String: Any] else {
                logger.warning("Config YAML is not a dictionary, using defaults")
                return OrcConfig.default
            }
            parsed = result
        } catch {
            logger.warning("Failed to parse config YAML, using defaults: \(error)")
            return OrcConfig.default
        }

        var config = OrcConfig.default

        // Parse concurrency section.
        if let concurrency = parsed["concurrency"] as? [String: Any],
           let maxParallel = concurrency["max_parallel_nodes"] as? Int
        {
            config.maxParallelNodes = maxParallel
        }

        // Parse storage section.
        if let storage = parsed["storage"] as? [String: Any] {
            if let days = storage["retention_days"] as? Int {
                config.retentionDays = days
            }
            if let policy = storage["retention_policy"] as? String {
                config.retentionPolicy = policy
            }
        }

        // Parse providers section. Each key is a provider name, value is its config dict.
        if let providersDict = parsed["providers"] as? [String: Any] {
            for (providerName, providerValue) in providersDict {
                guard let providerDict = providerValue as? [String: Any] else { continue }

                let providerConfig = ProviderConfig(
                    path: providerDict["path"] as? String,
                    type: providerDict["type"] as? String,
                    command: providerDict["command"] as? String,
                    interactiveCommand: providerDict["interactive_command"] as? String,
                    defaultModel: providerDict["default_model"] as? String,
                    defaultShell: providerDict["default_shell"] as? String
                )
                config.providers[providerName] = providerConfig

                // If the shell provider specifies default_shell, propagate to top-level.
                if providerName == "shell", let shell = providerDict["default_shell"] as? String {
                    config.defaultShell = shell
                }
            }
        }

        // Parse output section.
        if let output = parsed["output"] as? [String: Any] {
            if let verbose = output["verbose"] as? Bool {
                config.verbose = verbose
            }
        }

        // Also support flat keys at the top level for backward compatibility.
        if let maxParallel = parsed["max_parallel_nodes"] as? Int {
            config.maxParallelNodes = maxParallel
        }
        if let days = parsed["retention_days"] as? Int {
            config.retentionDays = days
        }
        if let policy = parsed["retention_policy"] as? String {
            config.retentionPolicy = policy
        }
        if let shell = parsed["default_shell"] as? String {
            config.defaultShell = shell
        }
        if let verbose = parsed["verbose"] as? Bool {
            config.verbose = verbose
        }

        return config
    }

    private func resolveKey(_ key: String, in config: OrcConfig) -> String? {
        switch key {
        case "concurrency.max_parallel_nodes", "max_parallel_nodes":
            return String(config.maxParallelNodes)
        case "storage.retention_days", "retention.days", "retention_days":
            return String(config.retentionDays)
        case "storage.retention_policy", "retention.policy", "retention_policy":
            return config.retentionPolicy
        case "default_shell":
            return config.defaultShell
        case "output.verbose", "verbose":
            return String(config.verbose)
        default:
            return nil
        }
    }

    /// Loads a YAML file into a dictionary, returning an empty dict if the file
    /// does not exist or is empty.
    private func loadYAMLDictionary(at path: String) -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let contents = String(data: data, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return [:]
        }
        do {
            guard let parsed = try Yams.load(yaml: contents) as? [String: Any] else {
                logger.warning("YAML at \(path) is not a dictionary, using empty dictionary")
                return [:]
            }
            return parsed
        } catch {
            logger.warning("Failed to parse YAML at \(path), using empty dictionary: \(error)")
            return [:]
        }
    }

    /// Serializes a dictionary back to YAML text.
    private func serializeYAML(_ dict: [String: Any]) throws -> String {
        // Yams.dump works with Node, so we convert through a simpler path:
        // serialize the dict using Yams directly.
        guard let yamlString = try? Yams.dump(object: dict, allowUnicode: true) else {
            // Fallback: write key-value pairs manually for simple dicts.
            var lines: [String] = []
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                lines.append("\(key): \(value)")
            }
            return lines.joined(separator: "\n") + "\n"
        }
        return yamlString
    }

    /// Converts a string value to Int or Bool if possible, for YAML type fidelity.
    private func autoTypedValue(_ value: String) -> Any {
        if let intVal = Int(value) { return intVal }
        if value == "true" { return true }
        if value == "false" { return false }
        return value
    }

    /// Sets a value in a nested dictionary by walking the key path.
    private func setNestedValue(in dict: inout [String: Any], keys: [String], value: Any) {
        guard let first = keys.first else { return }

        if keys.count == 1 {
            // Merge if both existing and new values are dictionaries.
            if let existingDict = dict[first] as? [String: Any],
               let newDict = value as? [String: Any] {
                dict[first] = existingDict.merging(newDict) { _, new in new }
            } else {
                dict[first] = value
            }
        } else {
            var nested = dict[first] as? [String: Any] ?? [:]
            setNestedValue(in: &nested, keys: Array(keys.dropFirst()), value: value)
            dict[first] = nested
        }
    }

    /// Removes a value from a nested dictionary by walking the key path.
    private func removeNestedValue(from dict: inout [String: Any], keys: [String]) {
        guard keys.count > 1 else {
            if let key = keys.first {
                dict.removeValue(forKey: key)
            }
            return
        }

        let first = keys[0]
        guard var nested = dict[first] as? [String: Any] else { return }
        removeNestedValue(from: &nested, keys: Array(keys.dropFirst()))
        if nested.isEmpty {
            dict.removeValue(forKey: first)
        } else {
            dict[first] = nested
        }
    }
}

// MARK: - OrcConfig

/// Top-level configuration for the Orc engine.
public struct OrcConfig: Sendable, Equatable {
    public var maxParallelNodes: Int
    public var retentionDays: Int
    public var retentionPolicy: String
    public var defaultShell: String
    public var verbose: Bool
    public var providers: [String: ProviderConfig]

    public init(
        maxParallelNodes: Int = ProcessInfo.processInfo.processorCount,
        retentionDays: Int = 30,
        retentionPolicy: String = "completed_only",
        defaultShell: String = Platform.defaultShell,
        verbose: Bool = false,
        providers: [String: ProviderConfig] = [:]
    ) {
        self.maxParallelNodes = maxParallelNodes
        self.retentionDays = retentionDays
        self.retentionPolicy = retentionPolicy
        self.defaultShell = defaultShell
        self.verbose = verbose
        self.providers = providers
    }

    public static let `default` = OrcConfig(
        maxParallelNodes: ProcessInfo.processInfo.processorCount,
        retentionDays: 30,
        retentionPolicy: "completed_only",
        defaultShell: Platform.defaultShell,
        verbose: false,
        providers: [:]
    )
}

// MARK: - ProviderConfig

/// Configuration for an individual agent provider.
public struct ProviderConfig: Sendable, Equatable {
    public let path: String?
    public let type: String?
    public let command: String?
    public let interactiveCommand: String?
    public let defaultModel: String?
    public let defaultShell: String?

    public init(
        path: String? = nil,
        type: String? = nil,
        command: String? = nil,
        interactiveCommand: String? = nil,
        defaultModel: String? = nil,
        defaultShell: String? = nil
    ) {
        self.path = path
        self.type = type
        self.command = command
        self.interactiveCommand = interactiveCommand
        self.defaultModel = defaultModel
        self.defaultShell = defaultShell
    }
}
