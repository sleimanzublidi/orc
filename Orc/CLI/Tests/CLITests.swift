import Foundation
import Testing
@testable import CLI

/// Smoke tests for CLI module types.
///
/// The CLI is an executable target with `@main`, so full integration tests
/// (parsing real commands) are limited. These tests verify that key internal
/// types are accessible and behave correctly.
@Suite("CLI - Smoke Tests")
struct CLISmokeTests {

    @Test("OrcDirectory.find() returns nil when no .orc directory exists")
    func orcDirectoryFindReturnsNilInTmpDir() throws {
        // Save and restore the cwd to avoid side effects on other tests.
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        // Use a temp directory that definitely does not contain .orc/
        let tmp = NSTemporaryDirectory()
            .appending("orc-cli-test-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        FileManager.default.changeCurrentDirectoryPath(tmp)
        #expect(OrcDirectory.find() == nil)
    }
}
