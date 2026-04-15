import Testing
@testable import Server
import Hummingbird
import HummingbirdTesting
import Models
import Engine
import Foundation

private final class MockRouteEngine: OrcEngineProviding, @unchecked Sendable {
    var listRunsResult: [Run] = []
    var getStatusResult: Run?
    var getNodeExecutionsResult: [NodeExecution] = []
    var getLogsResult: [LogEntry] = []
    var getStatsResult: [RunStats] = []
    var catalogResult: Catalog = Catalog(workflows: [], evaluators: [])

    var basePath: String { "/tmp" }

    func listRuns(status: RunStatus?, topLevelOnly: Bool) async throws -> [Run] {
        if let status {
            return listRunsResult.filter { $0.status == status }
        }
        return listRunsResult
    }
    func getStatus(runID: String) async throws -> Run? { getStatusResult }
    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] { getNodeExecutionsResult }
    func getLogs(runID: String, nodeID: String?, attempt: Int?, iteration: Int?) async throws -> [LogEntry] { getLogsResult }
    func getStats() async throws -> [RunStats] { getStatsResult }
    func catalog() async throws -> Catalog { catalogResult }

    func start(workflowFile: String, inputs: [String: String], maxParallelNodes: Int?) async throws -> Run { fatalError() }
    func resume(runID: String) async throws -> Run { fatalError() }
    func cancel(runID: String) async throws { fatalError() }
    func respond(runID: String, nodeID: String, response: String) async throws { fatalError() }
    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult) { fatalError() }
    func getConfigValue(key: String) async throws -> String? { fatalError() }
    func setConfigValue(key: String, value: String) async throws { fatalError() }
    func unsetConfigValue(key: String) async throws { fatalError() }
    func loadConfig() async throws -> OrcConfig { fatalError() }
    func cleanupWorkspace(runID: String) async throws { fatalError() }
    func cleanupRuns(olderThan: Date?, status: RunStatus?) async throws -> Int { fatalError() }
    func purge(olderThan: Date?, status: RunStatus?) async throws { fatalError() }
}

private func buildTestApp(engine: MockRouteEngine) -> some ApplicationProtocol {
    let router = Router()
    registerAPIRoutes(on: router, engine: engine)
    return Application(router: router)
}

@Suite("API Routes")
struct RouteTests {

    @Test("GET /api/health returns ok")
    func healthCheck() async throws {
        let engine = MockRouteEngine()
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("ok"))
            }
        }
    }

    @Test("GET /api/runs returns runs list")
    func listRuns() async throws {
        let engine = MockRouteEngine()
        engine.listRunsResult = [
            Run(id: "r001", workflowName: "test", workflowFile: "test.yml",
                status: .running, workspacePath: "/tmp", inputs: nil,
                output: nil, cleanupPolicy: .never,
                createdAt: Date(), updatedAt: Date())
        ]
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("r001"))
                #expect(body.contains("test"))
            }
        }
    }

    @Test("GET /api/runs/:id returns 404 for missing run")
    func missingRun() async throws {
        let engine = MockRouteEngine()
        engine.getStatusResult = nil
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs/nonexistent", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("GET /api/runs/:id returns run detail")
    func runDetail() async throws {
        let engine = MockRouteEngine()
        engine.getStatusResult = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .completed, workspacePath: "/tmp", inputs: nil,
            output: "done", cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs/r001", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("r001"))
                #expect(body.contains("completed"))
            }
        }
    }

    @Test("GET /api/runs/:id/nodes returns node executions")
    func nodeExecutions() async throws {
        let engine = MockRouteEngine()
        engine.getNodeExecutionsResult = [
            NodeExecution(
                id: "n001", runID: "r001", nodeID: "lint",
                status: .completed, agent: "shell",
                attempt: 1, iteration: 1,
                prompt: nil, message: nil, output: "ok", error: nil,
                tmuxSession: nil,
                startedAt: Date(), completedAt: Date()
            )
        ]
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs/r001/nodes", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("lint"))
                #expect(body.contains("completed"))
            }
        }
    }

    @Test("GET /api/stats returns stats")
    func stats() async throws {
        let engine = MockRouteEngine()
        engine.getStatsResult = [
            RunStats(id: 1, runID: "r001", workflowName: "test",
                     status: .completed, nodeCount: 3,
                     durationSeconds: 45.2, completedAt: Date())
        ]
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/stats", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("test"))
                #expect(body.contains("45.2"))
            }
        }
    }

    @Test("GET /api/catalog returns catalog")
    func catalog() async throws {
        let engine = MockRouteEngine()
        engine.catalogResult = Catalog(
            workflows: [CatalogEntry(name: "deploy", description: "Deploy pipeline", fileName: "deploy.yml")],
            evaluators: []
        )
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/catalog", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("deploy"))
            }
        }
    }
}
