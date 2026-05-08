import Foundation
import Models

/// Unpacks `.orc-workflow` archives into a project's `.orc/` directory.
///
/// The installer:
/// 1. Extracts the archive to a temporary directory.
/// 2. Reads + validates `manifest.yaml`.
/// 3. Verifies every path in `files:` is present and within `files/`.
/// 4. By default, refuses to overwrite existing files in the project; `--force`
///    overrides this.
enum WorkflowInstaller {
    enum Error: Swift.Error, CustomStringConvertible {
        case archiveNotFound(String)
        case unzipCommandFailed(Int32, String)
        case missingManifest
        case manifestDecode(String)
        case missingPackagedFile(String)
        case escapingPath(String)
        case existingFiles([String])

        var description: String {
            switch self {
            case .archiveNotFound(let path):
                return "package not found: \(path)"
            case .unzipCommandFailed(let status, let stderr):
                let detail = stderr.isEmpty ? "" : ": \(stderr)"
                return "unzip command failed with status \(status)\(detail)"
            case .missingManifest:
                return "package is missing manifest.yaml at the archive root"
            case .manifestDecode(let detail):
                return "manifest.yaml could not be decoded: \(detail)"
            case .missingPackagedFile(let path):
                return "manifest references '\(path)' but it is not present in the archive"
            case .escapingPath(let path):
                return "manifest references a path that escapes the package: '\(path)'"
            case .existingFiles(let paths):
                let list = paths.joined(separator: ", ")
                return "would overwrite existing files: \(list). Re-run with --force to replace them."
            }
        }
    }

    enum Action: Sendable, Equatable {
        case added(String)
        case replaced(String)
    }

    struct Result {
        var manifest: WorkflowPackageManifest
        var actions: [Action]
    }

    /// Installs `archivePath` into the `.orc/` directory at `basePath`.
    ///
    /// - Parameters:
    ///   - archivePath: Absolute path to the `.orc-workflow` package.
    ///   - basePath: Absolute path to the project's `.orc/` directory.
    ///   - force: When true, overwrite existing files. When false, error if any
    ///     would be overwritten.
    static func install(
        archivePath: String,
        basePath: String,
        force: Bool
    ) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archivePath) else {
            throw Error.archiveNotFound(archivePath)
        }
        if !fm.fileExists(atPath: basePath) {
            try fm.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        }

        let extractDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orc-install-\(UUID().uuidString)")
        try fm.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: extractDir) }

        try runUnzip(archivePath: archivePath, destination: extractDir)

        let manifestPath = extractDir.appendingPathComponent(WorkflowPackage.manifestName)
        guard fm.fileExists(atPath: manifestPath) else {
            throw Error.missingManifest
        }
        let manifestYAML: String
        do {
            manifestYAML = try String(contentsOfFile: manifestPath, encoding: .utf8)
        } catch {
            throw Error.manifestDecode("reading manifest.yaml: \(error)")
        }
        let manifest: WorkflowPackageManifest
        do {
            manifest = try WorkflowPackageManifestCoder.decode(manifestYAML)
        } catch {
            throw Error.manifestDecode(String(describing: error))
        }

        // Verify each manifested file exists in the archive and lives under files/.
        let stagedRoot = extractDir.appendingPathComponent(WorkflowPackage.filesPrefix)
        for relative in manifest.files {
            try assertSafeRelativePath(relative)
            let stagedPath = stagedRoot.appendingPathComponent(relative)
            if !fm.fileExists(atPath: stagedPath) {
                throw Error.missingPackagedFile(relative)
            }
        }

        // Pre-flight collision check before mutating the project.
        if !force {
            var collisions: [String] = []
            for relative in manifest.files {
                let target = basePath.appendingPathComponent(relative)
                if fm.fileExists(atPath: target) {
                    collisions.append(relative)
                }
            }
            if !collisions.isEmpty {
                throw Error.existingFiles(collisions)
            }
        }

        // Copy each file into place, recording the action for the caller.
        var actions: [Action] = []
        for relative in manifest.files {
            let source = stagedRoot.appendingPathComponent(relative)
            let destination = basePath.appendingPathComponent(relative)
            let parent = destination.deletingLastPathComponent
            if !fm.fileExists(atPath: parent) {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            let existed = fm.fileExists(atPath: destination)
            if existed {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
            actions.append(existed ? .replaced(relative) : .added(relative))
        }

        return Result(manifest: manifest, actions: actions)
    }

    // MARK: - Helpers

    /// Rejects paths that contain `..`, are absolute, or are otherwise crafted
    /// to escape the project's `.orc/` directory.
    private static func assertSafeRelativePath(_ path: String) throws {
        if path.hasPrefix("/") {
            throw Error.escapingPath(path)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            if part == ".." {
                throw Error.escapingPath(path)
            }
        }
    }

    private static func runUnzip(archivePath: String, destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archivePath, "-d", destination]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw Error.unzipCommandFailed(-1, "could not launch unzip: \(error)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw Error.unzipCommandFailed(process.terminationStatus, stderr)
        }
    }
}
