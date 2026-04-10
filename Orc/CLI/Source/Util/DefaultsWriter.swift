import Foundation

/// Writes embedded default files into a .orc/ directory.
enum DefaultsWriter {
    enum Action: Sendable {
        case added(String)
        case replaced(String)
    }

    /// Writes all embedded defaults into the given .orc/ directory.
    /// In force mode, overwrites existing files. Otherwise skips them.
    @discardableResult
    static func write(to orcDir: String, force: Bool = false) throws -> [Action] {
        let fm = FileManager.default
        var actions: [Action] = []

        // Ensure subdirectories exist.
        for dir in EmbeddedDefaults.directories {
            let dirPath = (orcDir as NSString).appendingPathComponent(dir)
            if !fm.fileExists(atPath: dirPath) {
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }
        }

        // Write files.
        for entry in EmbeddedDefaults.files {
            let dstPath = (orcDir as NSString).appendingPathComponent(entry.path)

            // Ensure parent directory exists.
            let parent = (dstPath as NSString).deletingLastPathComponent
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
