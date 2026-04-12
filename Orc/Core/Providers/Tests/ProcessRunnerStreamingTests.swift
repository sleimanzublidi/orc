import Foundation
import Testing

@testable import Providers

@Suite("ProcessRunner Streaming")
struct ProcessRunnerStreamingTests {
    let runner = ProcessRunner()

    @Test("Streams stdout chunks from echo command")
    func streamStdout() async throws {
        let stdoutPath = NSTemporaryDirectory() + "orc-test-stream-stdout-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: stdoutPath) }

        let stream = runner.runStreaming(
            command: "echo 'hello streaming'",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: nil,
            stdoutPath: stdoutPath,
            stderrPath: nil
        )

        var gotStdout = false
        var gotCompleted = false
        var stdoutContent = Data()

        for try await event in stream {
            switch event {
            case .stdout(let data):
                gotStdout = true
                stdoutContent.append(data)
            case .stderr:
                break
            case .completed(let result):
                gotCompleted = true
                #expect(result.exitCode == 0)
            }
        }

        #expect(gotStdout)
        #expect(gotCompleted)
        let text = String(data: stdoutContent, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "hello streaming")

        // Verify log file also has the content
        let fileContent = FileManager.default.contents(atPath: stdoutPath)
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fileContent == "hello streaming")
    }

    @Test("Streams stderr chunks")
    func streamStderr() async throws {
        let stderrPath = NSTemporaryDirectory() + "orc-test-stream-stderr-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: stderrPath) }

        let stream = runner.runStreaming(
            command: "echo 'error output' >&2",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: nil,
            stdoutPath: nil,
            stderrPath: stderrPath
        )

        var gotStderr = false
        var stderrContent = Data()

        for try await event in stream {
            switch event {
            case .stdout:
                break
            case .stderr(let data):
                gotStderr = true
                stderrContent.append(data)
            case .completed(let result):
                #expect(result.exitCode == 0)
            }
        }

        #expect(gotStderr)
        let text = String(data: stderrContent, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "error output")
    }

    @Test("Reports non-zero exit code in completed event")
    func nonZeroExit() async throws {
        let stream = runner.runStreaming(
            command: "exit 42",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: nil,
            stdoutPath: nil,
            stderrPath: nil
        )

        var completedExitCode: Int32?

        for try await event in stream {
            if case .completed(let result) = event {
                completedExitCode = result.exitCode
            }
        }

        #expect(completedExitCode == 42)
    }

    @Test("Timeout throws ProviderError.timeout")
    func timeoutThrows() async throws {
        let stream = runner.runStreaming(
            command: "sleep 60",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: 1,
            stdoutPath: nil,
            stderrPath: nil
        )

        await #expect(throws: ProviderError.self) {
            for try await _ in stream {}
        }
    }
}
