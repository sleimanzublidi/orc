import Testing
import Foundation
import Models
@testable import Engine

@Suite("WorkflowEngine Streaming")
struct WorkflowEngineStreamingTests {

    @Test("Default OrcEngineProviding implementation wraps start() result")
    func defaultImplementation() async throws {
        // Tests the protocol default by using a minimal mock that only
        // implements start(). The default startStreaming() should call
        // start() and wrap the result as a single runCompleted event.
        let engine = SimpleStreamingMock()
        let stream = try await engine.startStreaming(
            workflowFile: "/tmp/test.yml",
            inputs: [:],
            maxParallelNodes: nil
        )

        var events: [WorkflowEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 1)
        if case .runCompleted(let run) = events.first {
            #expect(run.status == .completed)
            #expect(run.id == "test-1")
        } else {
            Issue.record("Expected runCompleted event, got \(String(describing: events.first))")
        }
    }

    @Test("Default implementation yields runFailed for failed runs")
    func defaultImplementationFailed() async throws {
        let engine = SimpleStreamingMock(runStatus: .failed)
        let stream = try await engine.startStreaming(
            workflowFile: "/tmp/test.yml",
            inputs: [:],
            maxParallelNodes: nil
        )

        var events: [WorkflowEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 1)
        if case .runFailed(let run, let error) = events.first {
            #expect(run.status == .failed)
            #expect(error == "Run failed")
        } else {
            Issue.record("Expected runFailed event, got \(String(describing: events.first))")
        }
    }

    @Test("Default implementation passes inputs through to start()")
    func defaultImplementationPassesInputs() async throws {
        let engine = SimpleStreamingMock()
        let expectedInputs = ["key": "value", "foo": "bar"]

        let stream = try await engine.startStreaming(
            workflowFile: "/tmp/test.yml",
            inputs: expectedInputs,
            maxParallelNodes: 4
        )

        // Drain the stream.
        for try await _ in stream {}

        // Verify start() received the inputs.
        #expect(engine.lastInputs == expectedInputs)
        #expect(engine.lastMaxParallel == 4)
        #expect(engine.lastWorkflowFile == "/tmp/test.yml")
    }
}

// MARK: - Test Helpers

/// Minimal mock that only implements `start()` — relies on the default
/// `startStreaming()` extension on `OrcEngineProviding`.
private final class SimpleStreamingMock: OrcEngineProviding, @unchecked Sendable {
    var basePath: String = "/tmp/mock"

    private let runStatus: RunStatus
    var lastWorkflowFile: String?
    var lastInputs: [String: String]?
    var lastMaxParallel: Int?

    init(runStatus: RunStatus = .completed) {
        self.runStatus = runStatus
    }

    func start(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int?
    ) async throws -> Run {
        lastWorkflowFile = workflowFile
        lastInputs = inputs
        lastMaxParallel = maxParallelNodes
        return Run(
            id: "test-1",
            workflowName: "test",
            workflowFile: workflowFile,
            status: runStatus,
            workspacePath: "/tmp/ws"
        )
    }

    // Stubs for remaining protocol requirements — not exercised by these tests.
    func resume(runID: String) async throws -> Run { fatalError("not implemented") }
    func cancel(runID: String) async throws { fatalError("not implemented") }
    func respond(runID: String, nodeID: String, response: String) async throws { fatalError("not implemented") }
    func listRuns(status: RunStatus?) async throws -> [Run] { [] }
    func getStatus(runID: String) async throws -> Run? { nil }
    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] { [] }
    func getLogs(runID: String, nodeID: String?, attempt: Int?, iteration: Int?) async throws -> [LogEntry] { [] }
    func getStats() async throws -> [RunStats] { [] }
    func catalog() async throws -> Catalog { Catalog(workflows: [], evaluators: []) }
    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult) { fatalError("not implemented") }
    func getConfigValue(key: String) async throws -> String? { nil }
    func setConfigValue(key: String, value: String) async throws {}
    func unsetConfigValue(key: String) async throws {}
    func loadConfig() async throws -> OrcConfig { OrcConfig() }
    func cleanupWorkspace(runID: String) async throws {}
    func purge(olderThan: Date?, status: RunStatus?) async throws {}
}
