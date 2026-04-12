import Foundation
import Models
import Testing

@testable import Providers

@Suite("CLIAgentProvider Streaming")
struct CLIAgentProviderStreamingTests {

    @Test("Streams stdout chunks and completes")
    func streamStdout() async throws {
        let fakeRunner = FakeProcessRunner()
        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                continuation.yield(.stdout("output chunk".data(using: .utf8)!))
                if let path = stdoutPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path,
                        contents: "output chunk".data(using: .utf8)
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

        let provider = CLIAgentProvider(
            name: "test-agent",
            commandTemplate: "mycommand {{prompt}}",
            processRunner: fakeRunner
        )
        let context = TaskContext(repoRoot: "/tmp", workspacePath: "/tmp/ws")

        let stream = provider.executeStreaming(prompt: "test", context: context)

        var gotOutput = false
        var gotCompleted = false

        for try await event in stream {
            switch event {
            case .output(let text, _):
                gotOutput = true
                #expect(text == "output chunk")
            case .completed(let output):
                gotCompleted = true
                #expect(output.exitStatus == 0)
            }
        }

        #expect(gotOutput)
        #expect(gotCompleted)
    }
}
