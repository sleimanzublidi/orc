import Foundation

/// Writes embedded default files into a .orc/ directory.
enum DefaultsWriter {
    enum Action: Sendable {
        case added(String)
        case replaced(String)
    }

    /// Writes all embedded defaults into the given .orc/ directory.
    /// In force mode, overwrites existing files. Otherwise skips them.
    /// Help content (help/) is excluded — it is only used at runtime by the help command.
    @discardableResult
    static func write(to orcDir: String, force: Bool = false) throws -> [Action] {
        let fm = FileManager.default
        var actions: [Action] = []

        // Ensure subdirectories exist (skip help/).
        for dir in EmbeddedDefaults.directories where !dir.hasPrefix("help") {
            let dirPath = orcDir.appendingPathComponent(dir)
            if !fm.fileExists(atPath: dirPath) {
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }
        }

        // Write files (skip help/).
        for entry in EmbeddedDefaults.files where !entry.path.hasPrefix("help/") {
            let dstPath = orcDir.appendingPathComponent(entry.path)

            // Ensure parent directory exists.
            let parent = dstPath.deletingLastPathComponent
            if !fm.fileExists(atPath: parent) {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }

            let isRootFile = !entry.path.contains("/")

            if !fm.fileExists(atPath: dstPath) {
                try entry.content.write(toFile: dstPath, atomically: true, encoding: .utf8)
                actions.append(.added(entry.path))
            } else if force && !isRootFile {
                // Force replaces files inside subdirectories (workflows, evaluators)
                // but never root-level files like config.yml which are user-owned.
                try entry.content.write(toFile: dstPath, atomically: true, encoding: .utf8)
                actions.append(.replaced(entry.path))
            }
        }

        return actions
    }
}
