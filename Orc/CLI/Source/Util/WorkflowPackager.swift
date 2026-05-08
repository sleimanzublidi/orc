import Engine
import Foundation
import Models

/// Builds `.orc-workflow` archives from a workflow definition + its referenced files.
///
/// The packager walks the entrypoint workflow YAML, transitively follows `workflow:`
/// references to sub-workflows, and collects every `prompt_file:` referenced by any
/// node in the closure. The result is a single zip file with a `manifest.yaml` at the
/// root and a `files/` tree mirroring the project's `.orc/` layout.
enum WorkflowPackager {
    enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedReferencePath(String, nodeID: String)
        case fileNotFound(String)
        case validationFailed(String, [String])
        case zipCommandFailed(Int32, String)
        case stagingFailed(String)

        var description: String {
            switch self {
            case .unsupportedReferencePath(let path, let nodeID):
                return "node '\(nodeID)' references '\(path)'. Only paths anchored at '{{orc_root}}/' or '.orc/' can be packaged."
            case .fileNotFound(let path):
                return "referenced file does not exist: \(path)"
            case .validationFailed(let path, let errors):
                let detail = errors.joined(separator: "; ")
                return "workflow '\(path)' failed validation: \(detail)"
            case .zipCommandFailed(let status, let stderr):
                let detail = stderr.isEmpty ? "" : ": \(stderr)"
                return "zip command failed with status \(status)\(detail)"
            case .stagingFailed(let detail):
                return "failed to stage package contents: \(detail)"
            }
        }
    }

    struct Result {
        var manifest: WorkflowPackageManifest
        var outputPath: String
    }

    /// Packs the workflow named `workflowArgument` (a bare name or a path) into a
    /// `.orc-workflow` archive at `outputPath`.
    ///
    /// - Parameters:
    ///   - workflowArgument: The same form `orc validate` / `orc start` accept.
    ///   - basePath: Absolute path to the project's `.orc/` directory.
    ///   - outputPath: Absolute path where the archive should be written.
    ///   - version: Package version to record in the manifest (e.g. "1.0.0").
    ///   - description: Optional package description override; falls back to the entry
    ///     workflow's `description:` field.
    ///   - author: Optional author string.
    ///   - extraFiles: Additional paths (relative to `.orc/`) to include alongside
    ///     auto-discovered files. Useful for data files that the workflow references at
    ///     runtime via shell commands rather than `prompt_file:` / `workflow:`.
    ///   - engine: An engine instance used to parse and validate workflows.
    static func pack(
        workflowArgument: String,
        basePath: String,
        outputPath: String,
        version: String,
        description: String?,
        author: String?,
        extraFiles: [String],
        engine: some OrcEngineProviding
    ) async throws -> Result {
        let entryAbsolute = OrcDirectory.resolveWorkflowFile(workflowArgument, basePath: basePath)
        let entryRelative = try packageRelativePath(forAbsolute: entryAbsolute, basePath: basePath, nodeID: "<entrypoint>")

        // BFS over workflow files. Collect every file path (relative to .orc/) we need
        // to ship; deduplicate to keep the archive minimal.
        var queue: [String] = [entryAbsolute]
        var visitedWorkflows: Set<String> = []
        var collected: [String] = []
        var inserted: Set<String> = []

        func insertRelative(_ path: String) {
            if inserted.insert(path).inserted {
                collected.append(path)
            }
        }

        var entryDescription: String?
        var entryName: String?

        while !queue.isEmpty {
            let workflowPath = queue.removeFirst()
            if !visitedWorkflows.insert(workflowPath).inserted { continue }

            let (workflow, validation) = try await engine.validate(workflowFile: workflowPath)
            if !validation.isValid {
                let messages = validation.errors.map { error in
                    let prefix = error.nodeID.map { "[\($0)] " } ?? ""
                    return "\(prefix)\(error.message)"
                }
                throw Error.validationFailed(workflowPath, messages)
            }

            if workflowPath == entryAbsolute {
                entryDescription = workflow.description
                entryName = workflow.name
            }

            let workflowRelative = try packageRelativePath(forAbsolute: workflowPath, basePath: basePath, nodeID: "<workflow>")
            try assertFileExists(workflowPath)
            insertRelative(workflowRelative)

            for node in workflow.nodes {
                if let promptRef = node.promptFile {
                    let absolute = try resolveReferencedAbsolutePath(promptRef, basePath: basePath, nodeID: node.id)
                    let relative = try packageRelativePath(forAbsolute: absolute, basePath: basePath, nodeID: node.id)
                    try assertFileExists(absolute)
                    insertRelative(relative)
                }
                if let subWorkflowRef = node.workflow {
                    let absolute = try resolveReferencedAbsolutePath(subWorkflowRef, basePath: basePath, nodeID: node.id)
                    queue.append(absolute)
                }
            }
        }

        for extra in extraFiles {
            let normalized = normalizeExtraPath(extra)
            let absolute = basePath.appendingPathComponent(normalized)
            try assertFileExists(absolute)
            insertRelative(normalized)
        }

        let manifest = WorkflowPackageManifest(
            name: entryName ?? deriveName(fromOutputPath: outputPath),
            version: version,
            description: description ?? entryDescription,
            author: author,
            minOrcVersion: nil,
            entrypoint: entryRelative,
            files: collected
        )

        try writeArchive(
            manifest: manifest,
            collectedFiles: collected,
            basePath: basePath,
            outputPath: outputPath
        )

        return Result(manifest: manifest, outputPath: outputPath)
    }

    // MARK: - Path resolution

    /// Resolves a workflow-internal reference (`{{orc_root}}/...` or `.orc/...`) to an
    /// absolute path on disk. Throws when the reference uses an unsupported form (e.g.
    /// an absolute path or a different template variable).
    private static func resolveReferencedAbsolutePath(
        _ reference: String,
        basePath: String,
        nodeID: String
    ) throws -> String {
        let relative = try packageRelativePath(forReference: reference, nodeID: nodeID)
        return basePath.appendingPathComponent(relative)
    }

    /// Converts an absolute path under `.orc/` to a path relative to `.orc/`
    /// (used as the package-internal path).
    private static func packageRelativePath(
        forAbsolute absolutePath: String,
        basePath: String,
        nodeID: String
    ) throws -> String {
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard absolutePath.hasPrefix(normalizedBase) else {
            throw Error.unsupportedReferencePath(absolutePath, nodeID: nodeID)
        }
        return String(absolutePath.dropFirst(normalizedBase.count))
    }

    /// Strips the recognized `{{orc_root}}/` or `.orc/` prefix from a reference and
    /// returns the package-relative path. Unrecognized prefixes are rejected.
    private static func packageRelativePath(
        forReference reference: String,
        nodeID: String
    ) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = stripPrefix(trimmed, prefix: "{{orc_root}}/") {
            return stripped
        }
        if let stripped = stripPrefix(trimmed, prefix: ".orc/") {
            return stripped
        }
        throw Error.unsupportedReferencePath(reference, nodeID: nodeID)
    }

    private static func stripPrefix(_ string: String, prefix: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }

    private static func normalizeExtraPath(_ path: String) -> String {
        if let stripped = stripPrefix(path, prefix: ".orc/") { return stripped }
        if let stripped = stripPrefix(path, prefix: "{{orc_root}}/") { return stripped }
        return path
    }

    // MARK: - Archive assembly

    private static func writeArchive(
        manifest: WorkflowPackageManifest,
        collectedFiles: [String],
        basePath: String,
        outputPath: String
    ) throws {
        let fm = FileManager.default
        let tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orc-pack-\(UUID().uuidString)")

        do {
            try fm.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        } catch {
            throw Error.stagingFailed("creating staging dir: \(error)")
        }
        defer { try? fm.removeItem(atPath: tempRoot) }

        // Write manifest.yaml at the staging root.
        let manifestPath = tempRoot.appendingPathComponent(WorkflowPackage.manifestName)
        let manifestYAML = WorkflowPackageManifestCoder.encode(manifest)
        do {
            try manifestYAML.write(toFile: manifestPath, atomically: true, encoding: .utf8)
        } catch {
            throw Error.stagingFailed("writing manifest: \(error)")
        }

        // Stage each collected file under files/<relative>.
        let filesRoot = tempRoot.appendingPathComponent(WorkflowPackage.filesPrefix)
        for relative in collectedFiles {
            let source = basePath.appendingPathComponent(relative)
            let destination = filesRoot.appendingPathComponent(relative)
            let parent = destination.deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: source, toPath: destination)
            } catch {
                throw Error.stagingFailed("staging \(relative): \(error)")
            }
        }

        // Remove any existing output file so zip can write fresh.
        if fm.fileExists(atPath: outputPath) {
            try? fm.removeItem(atPath: outputPath)
        }
        let outputParent = outputPath.deletingLastPathComponent
        if !fm.fileExists(atPath: outputParent) {
            try fm.createDirectory(atPath: outputParent, withIntermediateDirectories: true)
        }

        try runZip(stagingDir: tempRoot, outputPath: outputPath)
    }

    private static func runZip(stagingDir: String, outputPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r recursive, -q quiet. Working directory = staging dir so paths in the
        // archive are relative (manifest.yaml and files/).
        process.arguments = ["-rq", outputPath, "."]
        process.currentDirectoryURL = URL(fileURLWithPath: stagingDir)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw Error.zipCommandFailed(-1, "could not launch zip: \(error)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw Error.zipCommandFailed(process.terminationStatus, stderr)
        }
    }

    // MARK: - Misc

    private static func assertFileExists(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            throw Error.fileNotFound(path)
        }
    }

    private static func deriveName(fromOutputPath outputPath: String) -> String {
        let last = (outputPath as NSString).lastPathComponent
        if let dot = last.lastIndex(of: ".") {
            return String(last[..<dot])
        }
        return last
    }
}
