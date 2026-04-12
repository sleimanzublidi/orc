import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("RespondCommand")
struct RespondCommandTests {

    @Test("text response sends text directly via engine.respond")
    func textResponse() async throws {
        let mock = MockEngine()
        var receivedRunID: String?
        var receivedNodeID: String?
        var receivedResponse: String?
        mock.respondHandler = { runID, nodeID, response in
            receivedRunID = runID
            receivedNodeID = nodeID
            receivedResponse = response
        }

        let cmd = try RespondCommand.parseAsRoot(["abc", "node1", "hello"]) as! RespondCommand
        try await cmd.execute(engine: mock)

        #expect(receivedRunID == "abc")
        #expect(receivedNodeID == "node1")
        #expect(receivedResponse == "hello")
    }

    @Test("throws when neither text nor file provided")
    func throwsWhenNoTextOrFile() async throws {
        let mock = MockEngine()

        let cmd = try RespondCommand.parseAsRoot(["abc", "node1"]) as! RespondCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("throws when file not readable")
    func throwsWhenFileNotReadable() async throws {
        let mock = MockEngine()

        let cmd = try RespondCommand.parseAsRoot([
            "abc", "node1", "--file", "/nonexistent/path/to/file.txt",
        ]) as! RespondCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("file response copies file to workspace artifacts dir and sends relative path")
    func fileResponseCopiesFile() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "orc-test-\(UUID().uuidString)"
        ).path

        // Create source file with known content.
        let sourceDir = tempDir.appendingPathComponent("source")
        try fm.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)
        let sourceFile = sourceDir.appendingPathComponent("response.txt")
        try "test file content".write(toFile: sourceFile, atomically: true, encoding: .utf8)

        // Create workspace directory (artifacts/ should be created by the command).
        let workspaceDir = tempDir.appendingPathComponent("workspace")
        try fm.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(atPath: tempDir)
        }

        let mock = MockEngine()
        mock.getStatusHandler = { _ in
            TestFixtures.makeRun(
                id: "abc",
                status: .awaitingInput,
                workspacePath: workspaceDir
            )
        }

        var capturedResponse: String?
        mock.respondHandler = { _, _, response in
            capturedResponse = response
        }

        let cmd = try RespondCommand.parseAsRoot([
            "abc", "node1", "--file", sourceFile,
        ]) as! RespondCommand
        try await cmd.execute(engine: mock)

        // Verify the response is the workspace-relative path.
        #expect(capturedResponse == "artifacts/response.txt")

        // Verify the file was actually copied to workspace/artifacts/.
        let copiedPath = workspaceDir
            .appendingPathComponent("artifacts/response.txt")
        #expect(fm.fileExists(atPath: copiedPath))

        // Verify the copied file has the correct content.
        let copiedContent = try String(contentsOfFile: copiedPath, encoding: .utf8)
        #expect(copiedContent == "test file content")
    }

    @Test("throws when run not found in file mode")
    func throwsWhenRunNotFoundInFileMode() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "orc-test-\(UUID().uuidString)"
        ).path

        // Create a readable source file so we get past the readability check.
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let sourceFile = tempDir.appendingPathComponent("data.txt")
        try "content".write(toFile: sourceFile, atomically: true, encoding: .utf8)

        defer {
            try? fm.removeItem(atPath: tempDir)
        }

        let mock = MockEngine()
        mock.getStatusHandler = { _ in nil }

        let cmd = try RespondCommand.parseAsRoot([
            "abc", "node1", "--file", sourceFile,
        ]) as! RespondCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }
}
