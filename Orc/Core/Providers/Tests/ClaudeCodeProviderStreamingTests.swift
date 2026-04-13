import Foundation
import Models
import Testing

@testable import Providers

@Suite("ClaudeCodeProvider Streaming")
struct ClaudeCodeProviderStreamingTests {

    @Test("Streams text_delta events from stream-json stdout")
    func streamTextDeltas() async throws {
        let fakeRunner = FakeProcessRunner()

        // Simulate NDJSON stream-json output with text_delta events
        let ndjsonLines = [
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello "}}}"#,
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"world"}}}"#,
            #"{"type":"result","result":"Hello world","session_id":"test-session"}"#,
        ]
        let ndjsonData = (ndjsonLines.joined(separator: "\n") + "\n").data(using: .utf8)!

        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                // Emit NDJSON on stdout as a single chunk
                continuation.yield(.stdout(ndjsonData))
                // Also emit some stderr progress
                continuation.yield(.stderr("Thinking...".data(using: .utf8)!))

                if let path = stdoutPath, path != "/dev/null" {
                    FileManager.default.createFile(atPath: path, contents: ndjsonData)
                }
                if let path = stderrPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path, contents: "Thinking...".data(using: .utf8)
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

        var stdoutChunks: [String] = []
        var stderrChunks: [String] = []
        var completedOutput: String?

        for try await event in stream {
            switch event {
            case .output(let text, let streamType):
                if streamType == .stdout {
                    stdoutChunks.append(text)
                } else {
                    stderrChunks.append(text)
                }
            case .completed(let output):
                completedOutput = output.output
            }
        }

        // text_delta events streamed as stdout chunks
        #expect(stdoutChunks == ["Hello ", "world"])
        // stderr also streamed
        #expect(!stderrChunks.isEmpty)
        // Final result from the "result" NDJSON message
        #expect(completedOutput == "Hello world")
    }

    @Test("Falls back to accumulated text when no result message")
    func fallsBackToAccumulatedText() async throws {
        let fakeRunner = FakeProcessRunner()

        // No "result" message — only text_delta events
        let ndjsonLines = [
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"accumulated "}}}"#,
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"output"}}}"#,
        ]
        let ndjsonData = (ndjsonLines.joined(separator: "\n") + "\n").data(using: .utf8)!

        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                continuation.yield(.stdout(ndjsonData))
                if let path = stdoutPath, path != "/dev/null" {
                    FileManager.default.createFile(atPath: path, contents: ndjsonData)
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

        let stream = provider.executeStreaming(prompt: "test", context: context)

        var completedOutput: String?
        for try await event in stream {
            if case .completed(let output) = event {
                completedOutput = output.output
            }
        }

        #expect(completedOutput == "accumulated output")
    }

    @Test("Handles NDJSON split across multiple stdout chunks")
    func handlesChunkedNDJSON() async throws {
        let fakeRunner = FakeProcessRunner()

        // Split a single NDJSON line across two data chunks
        let part1 = #"{"type":"stream_event","event":{"#.data(using: .utf8)!
        let part2 = #""delta":{"type":"text_delta","text":"split line"}}}"#.data(using: .utf8)!
        let newline = "\n".data(using: .utf8)!
        let resultLine = (#"{"type":"result","result":"split line"}"# + "\n").data(using: .utf8)!

        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                continuation.yield(.stdout(part1))
                continuation.yield(.stdout(part2))
                continuation.yield(.stdout(newline))
                continuation.yield(.stdout(resultLine))
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

        let stream = provider.executeStreaming(prompt: "test", context: context)

        var stdoutChunks: [String] = []
        var completedOutput: String?

        for try await event in stream {
            switch event {
            case .output(let text, .stdout):
                stdoutChunks.append(text)
            case .completed(let output):
                completedOutput = output.output
            default:
                break
            }
        }

        // The split line should be reassembled via the line buffer
        #expect(stdoutChunks == ["split line"])
        #expect(completedOutput == "split line")
    }

    @Test("Non-zero exit throws ProviderError")
    func nonZeroExitThrows() async throws {
        let fakeRunner = FakeProcessRunner()
        fakeRunner.streamingHandler = { _, _, stdoutPath, stderrPath in
            AsyncThrowingStream { continuation in
                if let path = stderrPath, path != "/dev/null" {
                    FileManager.default.createFile(
                        atPath: path, contents: "error details".data(using: .utf8)
                    )
                }
                continuation.yield(.completed(ProcessResult(
                    exitCode: 1,
                    stdoutPath: stdoutPath ?? "/dev/null",
                    stderrPath: stderrPath ?? "/dev/null"
                )))
                continuation.finish()
            }
        }

        let provider = ClaudeCodeProvider(processRunner: fakeRunner)
        let context = TaskContext(repoRoot: "/tmp", workspacePath: "/tmp/ws")

        let stream = provider.executeStreaming(prompt: "fail", context: context)

        await #expect(throws: ProviderError.self) {
            for try await _ in stream {}
        }
    }
}
