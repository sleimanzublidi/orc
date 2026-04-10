import ArgumentParser
import Engine

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View or modify Orc configuration"
    )

    @Argument(help: "Config key (dot notation, e.g., concurrency.max_parallel_nodes).")
    var key: String?

    @Argument(help: "Config value to set.")
    var value: String?

    @Flag(name: .long, help: "Remove a config key.")
    var unset: Bool = false

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            if let key = key {
                if unset {
                    // Unset the key.
                    try await engine.unsetConfigValue(key: key)
                    print("Removed '\(key)'.")
                } else if let value = value {
                    // Set the key.
                    try await engine.setConfigValue(key: key, value: value)
                    print("Set '\(key)' = '\(value)'.")
                } else {
                    // Get the key.
                    if let value = try await engine.getConfigValue(key: key) {
                        print(value)
                    } else {
                        Format.printError("Unknown config key '\(key)'.")
                        throw ExitCode.failure
                    }
                }
            } else {
                // No key: print all config using dot-notation keys so the
                // output matches what `orc config <key>` accepts.
                let config = try await engine.loadConfig()
                print("concurrency.max_parallel_nodes: \(config.maxParallelNodes)")
                print("storage.retention_days: \(config.retentionDays)")
                print("storage.retention_policy: \(config.retentionPolicy)")
                print("default_shell: \(config.defaultShell)")
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
