import ArgumentParser
import Foundation
import Models

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a .orc-workflow package into the current project"
    )

    @Argument(help: "Path to a .orc-workflow archive.")
    var archive: String

    @Flag(name: .long, help: "Overwrite existing files instead of erroring.")
    var force: Bool = false

    func run() async throws {
        let basePath = try OrcDirectory.require()
        try execute(basePath: basePath)
    }

    func execute(basePath: String) throws {
        let archivePath = absolutePath(archive)
        do {
            let result = try WorkflowInstaller.install(
                archivePath: archivePath,
                basePath: basePath,
                force: force
            )
            print("Installed '\(result.manifest.name)' v\(result.manifest.version)")
            for action in result.actions {
                switch action {
                case .added(let path):
                    print("  added: \(path)")
                case .replaced(let path):
                    print("  replaced: \(path)")
                }
            }
            if result.actions.isEmpty {
                print("  (no files written)")
            }
        } catch let error as WorkflowInstaller.Error {
            Format.printError("Error: \(error.description)")
            throw ExitCode.failure
        }
    }

    private func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let cwd = FileManager.default.currentDirectoryPath
        return cwd.appendingPathComponent(path)
    }
}
