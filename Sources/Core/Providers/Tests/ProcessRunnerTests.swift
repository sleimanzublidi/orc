import Foundation
import Testing

@testable import Providers

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    @Test("Runs a basic echo command and captures stdout")
    func basicEchoCommand() async throws {
        let stdoutPath = NSTemporaryDirectory() + "orc-test-stdout-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: stdoutPath) }

        let result = try await runner.run(
            command: "echo 'hello world'",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: nil,
            stdoutPath: stdoutPath,
            stderrPath: nil
        )

        #expect(result.exitCode == 0)

        let data = FileManager.default.contents(atPath: stdoutPath)
        let output = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "hello world")
    }

    @Test("Captures non-zero exit codes")
    func nonZeroExitCode() async throws {
        let result = try await runner.run(
            command: "exit 42",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: nil,
            stdoutPath: nil,
            stderrPath: nil
        )

        #expect(result.exitCode == 42)
    }

    @Test("Respects working directory")
    func workingDirectory() async throws {
        let stdoutPath = NSTemporaryDirectory() + "orc-test-stdout-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: stdoutPath) }

        let result = try await runner.run(
            command: "pwd",
            arguments: [],
            workingDirectory: "/tmp",
            environment: nil,
            timeout: nil,
            stdoutPath: stdoutPath,
            stderrPath: nil
        )

        #expect(result.exitCode == 0)

        let data = FileManager.default.contents(atPath: stdoutPath)
        let output = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // /tmp may resolve to /private/tmp on macOS
        #expect(output == "/tmp" || output == "/private/tmp")
    }

    @Test("Captures stderr output")
    func stderrCapture() async throws {
        let stderrPath = NSTemporaryDirectory() + "orc-test-stderr-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: stderrPath) }

        let result = try await runner.run(
            command: "echo 'error message' >&2",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: nil,
            stdoutPath: nil,
            stderrPath: stderrPath
        )

        #expect(result.exitCode == 0)

        let data = FileManager.default.contents(atPath: stderrPath)
        let output = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "error message")
    }

    @Test("Merges custom environment variables")
    func environmentMerge() async throws {
        let stdoutPath = NSTemporaryDirectory() + "orc-test-stdout-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: stdoutPath) }

        let result = try await runner.run(
            command: "echo $ORC_TEST_VAR",
            arguments: [],
            workingDirectory: nil,
            environment: ["ORC_TEST_VAR": "test_value_123"],
            timeout: nil,
            stdoutPath: stdoutPath,
            stderrPath: nil
        )

        #expect(result.exitCode == 0)

        let data = FileManager.default.contents(atPath: stdoutPath)
        let output = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "test_value_123")
    }
}
