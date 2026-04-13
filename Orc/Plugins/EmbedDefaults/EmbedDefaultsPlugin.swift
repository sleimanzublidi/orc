import Foundation
import PackagePlugin

@main
struct EmbedDefaultsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }

        let defaultsDir = sourceTarget.directoryURL.appending(path: "Resources/Defaults")
        // Help docs live at Docs/Help/ (repo root, one level above Package.swift)
        // but are embedded under the "help/" prefix alongside other defaults.
        let helpDir = context.package.directoryURL.deletingLastPathComponent().appending(path: "Docs/Help")
        let outputFile = context.pluginWorkDirectoryURL.appending(path: "EmbeddedDefaults.swift")

        var inputFiles = collectFiles(in: defaultsDir)
        inputFiles.append(contentsOf: collectFiles(in: helpDir))

        return [
            .buildCommand(
                displayName: "Embed default files into \(target.name)",
                executable: try context.tool(named: "EmbedDefaultsTool").url,
                arguments: [defaultsDir.path(), outputFile.path(), helpDir.path()],
                inputFiles: inputFiles,
                outputFiles: [outputFile]
            )
        ]
    }

    private func collectFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }
}
