import Testing
@testable import Server
import Engine
import Models
import Foundation

private final class MockEventEngine: OrcEngineProviding, @unchecked Sendable {
    var listRunsHandler: ((RunStatus?) async throws -> [Run])?
    var getNodeExecutionsHandler: ((String, String?) async throws -> [NodeExecution])?

    var basePath: String { "/tmp" }

    func listRuns(status: RunStatus?, topLevelOnly: Bool) async throws -> [Run] {
        try await listRunsHandler?(status) ?? []
    }
    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] {
        try await getNodeExecutionsHandler?(runID, nodeID) ?? []
    }

    func start(workflowFile: String, inputs: [String: String], maxParallelNodes: Int?) async throws -> Run { fatalError() }
    func resume(runID: String) async throws -> Run { fatalError() }
    func cancel(runID: String) async throws { fatalError() }
    func respond(runID: String, nodeID: String, response: String) async throws { fatalError() }
    func getStatus(runID: String) async throws -> Run? { fatalError() }
    func getLogs(runID: String, nodeID: String?, attempt: Int?, iteration: Int?) async throws -> [LogEntry] { fatalError() }
    func getStats() async throws -> [RunStats] { fatalError() }
    func catalog() async throws -> Catalog { fatalError() }
    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult) { fatalError() }
    func getConfigValue(key: String) async throws -> String? { fatalError() }
    func setConfigValue(key: String, value: String) async throws { fatalError() }
    func unsetConfigValue(key: String) async throws { fatalError() }
    func loadConfig() async throws -> OrcConfig { fatalError() }
    func cleanupWorkspace(runID: String) async throws { fatalError() }
    func cleanupRuns(olderThan: Date?, status: RunStatus?) async throws -> Int { fatalError() }
    func purge(olderThan: Date?, status: RunStatus?) async throws { fatalError() }
}

@Suite("PollingEventSource")
struct EventSourceTests {

    @Test("detects new run as run:created")
    func detectsNewRun() async {
        let mock = MockEventEngine()
        var callCount = 0

        let run = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .running, workspacePath: "/tmp", inputs: nil,
            output: nil, cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )

        mock.listRunsHandler = { _ in
            callCount += 1
            return callCount <= 1 ? [] : [run]
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let source = PollingEventSource(engine: mock, pollInterval: .milliseconds(50))
        var collected: [MonitorEvent] = []

        for await event in source.events() {
            collected.append(event)
            if case .runCreated = event { break }
            if collected.count > 30 { break }
        }
        await source.shutdown()

        let hasCreated = collected.contains { if case .runCreated = $0 { return true }; return false }
        #expect(hasCreated)
    }

    @Test("detects run status change as run:updated")
    func detectsRunStatusChange() async {
        let mock = MockEventEngine()
        var callCount = 0

        let runningRun = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .running, workspacePath: "/tmp", inputs: nil,
            output: nil, cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )
        let completedRun = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .completed, workspacePath: "/tmp", inputs: nil,
            output: "done", cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )

        mock.listRunsHandler = { _ in
            callCount += 1
            return callCount <= 1 ? [runningRun] : [completedRun]
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let source = PollingEventSource(engine: mock, pollInterval: .milliseconds(50))
        var collected: [MonitorEvent] = []

        for await event in source.events() {
            collected.append(event)
            if case .runUpdated = event { break }
            if collected.count > 30 { break }
        }
        await source.shutdown()

        let hasUpdated = collected.contains { if case .runUpdated = $0 { return true }; return false }
        #expect(hasUpdated)
    }

    @Test("emits heartbeat")
    func emitsHeartbeat() async {
        let mock = MockEventEngine()
        mock.listRunsHandler = { _ in [] }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let source = PollingEventSource(engine: mock, pollInterval: .milliseconds(10))
        var collected: [MonitorEvent] = []

        for await event in source.events() {
            collected.append(event)
            if case .heartbeat = event { break }
            if collected.count > 50 { break }
        }
        await source.shutdown()

        let hasHeartbeat = collected.contains { if case .heartbeat = $0 { return true }; return false }
        #expect(hasHeartbeat)
    }
}
