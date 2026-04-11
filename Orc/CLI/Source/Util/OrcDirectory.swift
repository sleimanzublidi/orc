import ArgumentParser
import Foundation

/// Locates the `.orc/` project directory by walking up from the cwd.
enum OrcDirectory {
    /// Walks up parent directories from the current working directory to find
    /// the `.orc/` project directory, similar to how Git finds `.git/`.
    ///
    /// - Returns: The absolute path to the `.orc/` directory, or nil if not found.
    static func find() -> String? {
        let fm = FileManager.default
        var current = fm.currentDirectoryPath

        while true {
            let candidate = (current as NSString).appendingPathComponent(".orc")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }

            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                return nil
            }
            current = parent
        }
    }

    /// Finds the `.orc/` directory or prints an error to stderr and exits.
    ///
    /// All commands except `init` and `version` use this to locate the project root.
    ///
    /// - Returns: The absolute path to the `.orc/` directory.
    static func require() throws -> String {
        guard let path = find() else {
            Format.printError("No .orc/ directory found. Run 'orc init' to create one.")
            throw ExitCode.failure
        }
        return path
    }

    /// Resolves a workflow file argument to an absolute path.
    ///
    /// If the argument is a bare name (no path separators, no `.yml`/`.yaml` extension),
    /// looks for it in `.orc/workflows/` with both extensions. Otherwise returns the
    /// argument unchanged.
    static func resolveWorkflowFile(_ argument: String, basePath: String) -> String {
        // Already a path (contains separator or has yaml extension) — use as-is.
        if argument.contains("/") || argument.hasSuffix(".yml") || argument.hasSuffix(".yaml") {
            return argument
        }

        let fm = FileManager.default
        let workflowsDir = (basePath as NSString).appendingPathComponent("workflows")

        for ext in ["yaml", "yml"] {
            let candidate = (workflowsDir as NSString).appendingPathComponent("\(argument).\(ext)")
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // Not found — return as-is and let the engine report the error.
        return argument
    }
}
