import Foundation
import Models
import Testing

@testable import Providers

@Suite("ClaudeCodeProvider Streaming")
struct ClaudeCodeProviderStreamingTests {

    @Test("Streams stderr progress, parses stdout JSON on completion")
    func streamStderrParseStdout() async throws {
        let fakeRunner = FakeProcessRunner()
        let jsonOutput = """
        [{"type":"result","result":"parsed result text"}]
        """
        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                continuation.yield(.stderr("Thinking...".data(using: .utf8)!))
                if let path = stdoutPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path,
                        contents: jsonOutput.data(using: .utf8)
                    )
                }
                if let path = stderrPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path,
                        contents: "Thinking...".data(using: .utf8)
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

        let provider = ClaudeCodeProvider(processRunner: fakeRunner)
        let context = TaskContext(repoRoot: "/tmp", workspacePath: "/tmp/ws")

        let stream = provider.executeStreaming(prompt: "test prompt", context: context)

        var stderrChunks: [String] = []
        var completedOutput: String?

        for try await event in stream {
            switch event {
            case .output(let text, let streamType):
                #expect(streamType == .stderr)
                stderrChunks.append(text)
            case .completed(let output):
                completedOutput = output.output
            }
        }

        #expect(!stderrChunks.isEmpty)
        #expect(completedOutput == "parsed result text")
    }
}
