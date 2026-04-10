import ArgumentParser
import Foundation
import Testing

@testable import CLI

/// Tests for `OrcDirectory`, which locates the `.orc/` project directory
/// by walking up from the current working directory.
@Suite("OrcDirectory")
struct OrcDirectoryTests {

    /// Creates a unique temp directory with symlinks resolved.
    ///
    /// macOS `/var/folders/` is a symlink to `/private/var/folders/`, but
    /// `FileManager.currentDirectoryPath` returns the resolved (canonical) path.
    /// We resolve via C `realpath()` after creation so expected paths match
    /// `OrcDirectory.find()` output.
    private func makeTempDir(suffix: String) throws -> String {
        let raw = NSTemporaryDirectory()
            .appending("orc-dir-test-\(suffix)-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(
            atPath: raw, withIntermediateDirectories: true)

        // Resolve symlinks now that the directory exists on disk.
        guard let resolved = realpath(raw, nil) else {
            return raw
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - find()

    @Test("find() returns nil when no .orc/ directory exists")
    func findReturnsNilWhenNoOrcDirectory() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        let tmp = try makeTempDir(suffix: "none")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        FileManager.default.changeCurrentDirectoryPath(tmp)
        #expect(OrcDirectory.find() == nil)
    }

    @Test("find() returns correct path when .orc/ exists in cwd")
    func findReturnsPathWhenOrcExistsInCwd() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        let tmp = try makeTempDir(suffix: "cwd")
        let orcDir = (tmp as NSString).appendingPathComponent(".orc")
        try FileManager.default.createDirectory(
            atPath: orcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        FileManager.default.changeCurrentDirectoryPath(tmp)

        let result = OrcDirectory.find()
        #expect(result == orcDir)
    }

    @Test("find() walks up to parent directory containing .orc/")
    func findWalksUpToParent() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        // Create: tmp/.orc/ and tmp/child/grandchild/
        // Set cwd to grandchild — find() should walk up and discover tmp/.orc/
        let tmp = try makeTempDir(suffix: "walk")
        let orcDir = (tmp as NSString).appendingPathComponent(".orc")
        let nested = (tmp as NSString)
            .appendingPathComponent("child/grandchild")
        try FileManager.default.createDirectory(
            atPath: orcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        FileManager.default.changeCurrentDirectoryPath(nested)

        let result = OrcDirectory.find()
        #expect(result == orcDir)
    }

    // MARK: - require()

    @Test("require() throws ExitCode.failure when .orc/ is not found")
    func requireThrowsWhenNotFound() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        let tmp = try makeTempDir(suffix: "req-fail")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        FileManager.default.changeCurrentDirectoryPath(tmp)

        #expect(throws: ExitCode.failure) {
            try OrcDirectory.require()
        }
    }

    @Test("require() returns path when .orc/ exists")
    func requireReturnsPathWhenFound() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        let tmp = try makeTempDir(suffix: "req-ok")
        let orcDir = (tmp as NSString).appendingPathComponent(".orc")
        try FileManager.default.createDirectory(
            atPath: orcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        FileManager.default.changeCurrentDirectoryPath(tmp)

        let result = try OrcDirectory.require()
        #expect(result == orcDir)
    }
}
