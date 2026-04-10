import ArgumentParser
import Models

public struct OrcCommand: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "orc",
        abstract: "Orchestrate AI agents via YAML-defined workflows",
        version: OrcVersion.current,
        subcommands: [
            InitCommand.self,
            ValidateCommand.self,
            StartCommand.self,
            ResumeCommand.self,
            ListCommand.self,
            StatusCommand.self,
            AttachCommand.self,
            RespondCommand.self,
            LogsCommand.self,
            CancelCommand.self,
            CleanupCommand.self,
            PurgeCommand.self,
            StatsCommand.self,
            ConfigCommand.self,
            VersionCommand.self,
        ]
    )
}
