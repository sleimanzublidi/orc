import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("WorkflowInstaller")
struct WorkflowInstallerTests {

    /// Creates a `.orc-workflow` archive from the supplied files and returns the
    /// archive path along with the staging directory's parent (for cleanup).
    private func makeArchive(
        manifest: WorkflowPackageManifest,
        contents: [String: String]
    ) throws -> (archive: String, parent: String) {
        let parent = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orc-installer-tests-\(UUID().uuidString)")
        let staging = parent.appendingPathComponent("staging")
        let archive = parent.appendingPathComponent("pkg.orc-workflow")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)

        let manifestPath = staging.appendingPathComponent(WorkflowPackage.manifestName)
        let manifestYAML = WorkflowPackageManifestCoder.encode(manifest)
        try manifestYAML.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let filesRoot = staging.appendingPathComponent(WorkflowPackage.filesPrefix)
        for (relative, body) in contents {
            let absolute = filesRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: absolute.deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try body.write(toFile: absolute, atomically: true, encoding: .utf8)
        }

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-rq", archive, "."]
        zip.currentDirectoryURL = URL(fileURLWithPath: staging)
        try zip.run()
        zip.waitUntilExit()
        return (archive, parent)
    }

    @Test("installs every manifest file into the project's .orc/ directory")
    func installsFiles() throws {
        let manifest = WorkflowPackageManifest(
            name: "demo",
            version: "1.0.0",
            description: nil,
            author: nil,
            minOrcVersion: nil,
            entrypoint: "workflows/demo.yaml",
            files: ["workflows/demo.yaml", "prompts/demo.md"]
        )
        let (archive, parent) = try makeArchive(
            manifest: manifest,
            contents: [
                "workflows/demo.yaml": "name: demo\n",
                "prompts/demo.md": "# demo prompt"
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let basePath = parent.appendingPathComponent("project/.orc")
        try FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)

        let result = try WorkflowInstaller.install(
            archivePath: archive,
            basePath: basePath,
            force: false
        )

        #expect(result.actions.count == 2)
        let workflowBody = try String(
            contentsOfFile: basePath.appendingPathComponent("workflows/demo.yaml"),
            encoding: .utf8
        )
        #expect(workflowBody == "name: demo\n")
        let promptBody = try String(
            contentsOfFile: basePath.appendingPathComponent("prompts/demo.md"),
            encoding: .utf8
        )
        #expect(promptBody == "# demo prompt")
    }

    @Test("errors when an existing file would be overwritten")
    func detectsCollisions() throws {
        let manifest = WorkflowPackageManifest(
            name: "demo",
            version: "1.0.0",
            description: nil,
            author: nil,
            minOrcVersion: nil,
            entrypoint: "workflows/demo.yaml",
            files: ["workflows/demo.yaml"]
        )
        let (archive, parent) = try makeArchive(
            manifest: manifest,
            contents: ["workflows/demo.yaml": "from package"]
        )
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let basePath = parent.appendingPathComponent("project/.orc")
        let target = basePath.appendingPathComponent("workflows/demo.yaml")
        try FileManager.default.createDirectory(
            atPath: target.deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "existing".write(toFile: target, atomically: true, encoding: .utf8)

        #expect(throws: WorkflowInstaller.Error.self) {
            _ = try WorkflowInstaller.install(
                archivePath: archive,
                basePath: basePath,
                force: false
            )
        }

        // Original file should be untouched.
        let body = try String(contentsOfFile: target, encoding: .utf8)
        #expect(body == "existing")
    }

    @Test("--force replaces existing files and reports them as replaced")
    func forceReplacesExisting() throws {
        let manifest = WorkflowPackageManifest(
            name: "demo",
            version: "1.0.0",
            description: nil,
            author: nil,
            minOrcVersion: nil,
            entrypoint: "workflows/demo.yaml",
            files: ["workflows/demo.yaml"]
        )
        let (archive, parent) = try makeArchive(
            manifest: manifest,
            contents: ["workflows/demo.yaml": "fresh body"]
        )
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let basePath = parent.appendingPathComponent("project/.orc")
        let target = basePath.appendingPathComponent("workflows/demo.yaml")
        try FileManager.default.createDirectory(
            atPath: target.deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "old".write(toFile: target, atomically: true, encoding: .utf8)

        let result = try WorkflowInstaller.install(
            archivePath: archive,
            basePath: basePath,
            force: true
        )
        #expect(result.actions == [.replaced("workflows/demo.yaml")])
        let body = try String(contentsOfFile: target, encoding: .utf8)
        #expect(body == "fresh body")
    }

    @Test("rejects manifest paths that escape the package")
    func rejectsPathTraversal() throws {
        let manifest = WorkflowPackageManifest(
            name: "evil",
            version: "1.0.0",
            description: nil,
            author: nil,
            minOrcVersion: nil,
            entrypoint: "workflows/x.yaml",
            files: ["../escape.txt"]
        )
        // Pack the staged content under "files/" with literal name "../escape.txt"
        // by laying out a normal file then editing the manifest. We can't actually
        // write a file at "../escape.txt" inside files/, so just point at a real path
        // and let the safety check fire on the manifest entry alone.
        let (archive, parent) = try makeArchive(
            manifest: manifest,
            contents: ["workflows/x.yaml": "name: x"]
        )
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let basePath = parent.appendingPathComponent("project/.orc")
        try FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)

        #expect(throws: WorkflowInstaller.Error.self) {
            _ = try WorkflowInstaller.install(
                archivePath: archive,
                basePath: basePath,
                force: true
            )
        }
    }

    @Test("errors when archive does not exist")
    func errorsOnMissingArchive() throws {
        let basePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orc-installer-missing-\(UUID().uuidString)/.orc")
        try FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: basePath.deletingLastPathComponent) }

        #expect(throws: WorkflowInstaller.Error.self) {
            _ = try WorkflowInstaller.install(
                archivePath: "/nonexistent/path.orc-workflow",
                basePath: basePath,
                force: false
            )
        }
    }
}
