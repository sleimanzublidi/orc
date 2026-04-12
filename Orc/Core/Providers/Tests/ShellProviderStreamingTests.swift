import Foundation
import Models
import Testing

@testable import Providers

@Suite("ShellProvider Streaming")
struct ShellProviderStreamingTests {
    let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/orc-test")

    @Test("Streams stdout chunks and completes")
    func streamStdoutAndComplete() async throws {
        let fakeRunner = FakeProcessRunner()
        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                continuation.yield(.stdout("hello ".data(using: .utf8)!))
                continuation.yield(.stdout("world".data(using: .utf8)!))
                // Write to stdout file for FileReader
                let fullOutput = "hello world"
                if let path = stdoutPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path,
                        contents: fullOutput.data(using: .utf8)
                    )
                }
                continuation.yield(.completed(ProcessResult(
                    exitCode: 0,
                    stdoutPath: stdoutPath ?? "/dev/null",
                    stderrPath: stderrPath ?? "/dev/null"
                )))
                continuation.finish()
            }
        }

        let provider = ShellProvider(processRunner: fakeRunner)
        let context = TaskContext(repoRoot: "/tmp", workspacePath: "/tmp/ws")

        let stream = provider.executeStreaming(
            prompt: "echo hello world",
            context: context
        )

        var chunks: [String] = []
        var completed = false

        for try await event in stream {
            switch event {
            case .output(let text, let streamType):
                #expect(streamType == .stdout)
                chunks.append(text)
            case .completed(let output):
                completed = true
                #expect(output.exitStatus == 0)
            }
        }

        #expect(!chunks.isEmpty)
        #expect(completed)
    }

    @Test("Non-zero exit throws ProviderError")
    func nonZeroExitThrows() async throws {
        let fakeRunner = FakeProcessRunner()
        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                if let path = stderrPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path,
                        contents: "bad thing".data(using: .utf8)
                    )
                }
                if let path = stdoutPath, path != "/dev/null" {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                continuation.yield(.completed(ProcessResult(
                    exitCode: 1,
                    stdoutPath: stdoutPath ?? "/dev/null",
                    stderrPath: stderrPath ?? "/dev/null"
                )))
                continuation.finish()
            }
        }

        let provider = ShellProvider(processRunner: fakeRunner)
        let context = TaskContext(repoRoot: "/tmp", workspacePath: "/tmp/ws")

        let stream = provider.executeStreaming(prompt: "fail", context: context)

        await #expect(throws: ProviderError.self) {
            for try await _ in stream {}
        }
    }
}
