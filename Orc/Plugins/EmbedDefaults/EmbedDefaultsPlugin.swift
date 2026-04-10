import Foundation
import PackagePlugin

@main
struct EmbedDefaultsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }

        let defaultsDir = sourceTarget.directoryURL.appending(path: "Resources/Defaults")
        let outputFile = context.pluginWorkDirectoryURL.appending(path: "EmbeddedDefaults.swift")

        return [
            .buildCommand(
                displayName: "Embed default files into \(target.name)",
                executable: try context.tool(named: "EmbedDefaultsTool").url,
                arguments: [defaultsDir.path(), outputFile.path()],
                inputFiles: collectFiles(in: defaultsDir),
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
