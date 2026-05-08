import ArgumentParser
import Engine
import Foundation
import Models

struct PackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Bundle a workflow and its referenced files into a .orc-workflow archive"
    )

    @Argument(help: "Workflow name (resolved under .orc/workflows/) or a path to a YAML file.")
    var workflow: String

    @Option(name: .shortAndLong, help: "Output path for the archive. Defaults to ./<workflow-name>.orc-workflow.")
    var output: String?

    @Option(name: .long, help: "Package version (semver-style). Defaults to 0.0.0.")
    var packageVersion: String = "0.0.0"

    @Option(name: .long, help: "Optional package description; falls back to the workflow's description field.")
    var description: String?

    @Option(name: .long, help: "Optional author string for the manifest.")
    var author: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Extra files (paths under .orc/) to include alongside auto-discovered files. Repeatable.")
    var include: [String] = []

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine, basePath: basePath)
    }

    func execute(engine: some OrcEngineProviding, basePath: String) async throws {
        let outputAbsolute = resolveOutputPath()
        do {
            let result = try await WorkflowPackager.pack(
                workflowArgument: workflow,
                basePath: basePath,
                outputPath: outputAbsolute,
                version: packageVersion,
                description: description,
                author: author,
                extraFiles: include,
                engine: engine
            )
            print("Packed '\(result.manifest.name)' v\(result.manifest.version) -> \(result.outputPath)")
            print("  files: \(result.manifest.files.count)")
            for path in result.manifest.files {
                print("    \(path)")
            }
        } catch let error as WorkflowPackager.Error {
            Format.printError("Error: \(error.description)")
            throw ExitCode.failure
        }
    }

    private func resolveOutputPath() -> String {
        if let provided = output {
            return absolutePath(provided)
        }
        let baseName = (workflow as NSString).lastPathComponent
        let nameWithoutExt: String
        if let dot = baseName.lastIndex(of: ".") {
            nameWithoutExt = String(baseName[..<dot])
        } else {
            nameWithoutExt = baseName
        }
        let cwd = FileManager.default.currentDirectoryPath
        return cwd.appendingPathComponent("\(nameWithoutExt).\(WorkflowPackage.fileExtension)")
    }

    private func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let cwd = FileManager.default.currentDirectoryPath
        return cwd.appendingPathComponent(path)
    }
}
