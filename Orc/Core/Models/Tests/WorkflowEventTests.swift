import Foundation
import Testing

@testable import Models

// MARK: - Codable Helpers

/// Encodes a value to JSON and decodes it back, returning the round-tripped result.
private func roundTrip<T: Codable & Sendable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - WorkflowEvent Tests

@Suite("WorkflowEvent")
struct WorkflowEventTests {

    // Helper run used across tests.
    private static let sampleRun = Run(
        id: "run-1",
        workflowName: "deploy",
        workflowFile: "deploy.yaml",
        status: .running,
        workspacePath: "/tmp/workspace"
    )

    @Test("all WorkflowEvent cases are constructible and pattern-matchable")
    func allCasesConstructible() {
        let run = Self.sampleRun

        let events: [WorkflowEvent] = [
            .runStarted(run),
            .runCompleted(run),
            .runFailed(run, error: "timeout"),
            .nodeStarted(nodeID: "n1", runID: "run-1", agent: "claude"),
            .nodeOutput(nodeID: "n1", runID: "run-1", chunk: "building...", stream: .stdout),
            .nodeCompleted(nodeID: "n1", runID: "run-1", output: "done"),
            .nodeFailed(nodeID: "n1", runID: "run-1", error: "compile error"),
            .nodeSkipped(nodeID: "n1", runID: "run-1"),
        ]

        // Verify each case matches the expected pattern.
        for event in events {
            switch event {
            case .runStarted(let r):
                #expect(r.id == "run-1")
            case .runCompleted(let r):
                #expect(r.id == "run-1")
            case .runFailed(let r, let error):
                #expect(r.id == "run-1")
                #expect(error == "timeout")
            case .nodeStarted(let nodeID, let runID, let agent):
                #expect(nodeID == "n1")
                #expect(runID == "run-1")
                #expect(agent == "claude")
            case .nodeOutput(let nodeID, let runID, let chunk, let stream):
                #expect(nodeID == "n1")
                #expect(runID == "run-1")
                #expect(chunk == "building...")
                #expect(stream == .stdout)
            case .nodeCompleted(let nodeID, let runID, let output):
                #expect(nodeID == "n1")
                #expect(runID == "run-1")
                #expect(output == "done")
            case .nodeFailed(let nodeID, let runID, let error):
                #expect(nodeID == "n1")
                #expect(runID == "run-1")
                #expect(error == "compile error")
            case .nodeSkipped(let nodeID, let runID):
                #expect(nodeID == "n1")
                #expect(runID == "run-1")
            }
        }
    }
}

// MARK: - OutputStreamType Tests

@Suite("OutputStreamType")
struct OutputStreamTypeTests {

    @Test("raw values are 'stdout' and 'stderr'")
    func rawValues() {
        #expect(OutputStreamType.stdout.rawValue == "stdout")
        #expect(OutputStreamType.stderr.rawValue == "stderr")
    }

    @Test("Codable round-trip for stdout")
    func stdoutRoundTrip() throws {
        let decoded = try roundTrip(OutputStreamType.stdout)
        #expect(decoded == .stdout)
    }

    @Test("Codable round-trip for stderr")
    func stderrRoundTrip() throws {
        let decoded = try roundTrip(OutputStreamType.stderr)
        #expect(decoded == .stderr)
    }
}

// MARK: - ProcessStreamEvent Tests

@Suite("ProcessStreamEvent")
struct ProcessStreamEventTests {

    @Test("all ProcessStreamEvent cases are constructible")
    func allCasesConstructible() {
        let stdoutData = Data("hello".utf8)
        let stderrData = Data("error".utf8)
        let result = ProcessResult(exitCode: 0, stdoutPath: "/tmp/out", stderrPath: "/tmp/err")

        let events: [ProcessStreamEvent] = [
            .stdout(stdoutData),
            .stderr(stderrData),
            .completed(result),
        ]

        for event in events {
            switch event {
            case .stdout(let data):
                #expect(data == stdoutData)
            case .stderr(let data):
                #expect(data == stderrData)
            case .completed(let r):
                #expect(r.exitCode == 0)
            }
        }
    }
}

// MARK: - AgentStreamEvent Tests

@Suite("AgentStreamEvent")
struct AgentStreamEventTests {

    @Test("all AgentStreamEvent cases are constructible")
    func allCasesConstructible() {
        let taskOutput = TaskOutput(output: "result", exitStatus: 0)

        let events: [AgentStreamEvent] = [
            .output("chunk", .stdout),
            .output("warning", .stderr),
            .completed(taskOutput),
        ]

        for event in events {
            switch event {
            case .output(let text, let stream):
                #expect(!text.isEmpty)
                #expect(stream == .stdout || stream == .stderr)
            case .completed(let out):
                #expect(out.output == "result")
                #expect(out.exitStatus == 0)
            }
        }
    }
}
