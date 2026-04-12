import Engine
import Foundation
import Models
@testable import CLI

/// Closure-based mock of `OrcEngineProviding` for command tests.
///
/// Each protocol method has a corresponding optional closure property.
/// If a handler is not set and the method is called, it calls `fatalError()`
/// to catch test bugs early (unhandled calls indicate a missing setup step).
final class MockEngine: OrcEngineProviding, @unchecked Sendable {
    var basePath: String = "/tmp/mock-orc/.orc"

    // MARK: - Core Operations

    var startHandler: ((String, [String: String], Int?) async throws -> Run)?
    var startStreamingHandler: ((String, [String: String], Int?) async throws -> AsyncThrowingStream<WorkflowEvent, any Error>)?
    var resumeHandler: ((String) async throws -> Run)?
    var cancelHandler: ((String) async throws -> Void)?
    var respondHandler: ((String, String, String) async throws -> Void)?

    // MARK: - Queries

    var listRunsHandler: ((RunStatus?) async throws -> [Run])?
    var getStatusHandler: ((String) async throws -> Run?)?
    var getNodeExecutionsHandler: ((String, String?) async throws -> [NodeExecution])?
    var getLogsHandler: ((String, String?, Int?, Int?) async throws -> [LogEntry])?
    var getStatsHandler: (() async throws -> [RunStats])?
    var catalogHandler: (() async throws -> Catalog)?

    // MARK: - Validation

    var validateHandler: ((String) async throws -> (Workflow, ValidationResult))?

    // MARK: - Configuration

    var getConfigValueHandler: ((String) async throws -> String?)?
    var setConfigValueHandler: ((String, String) async throws -> Void)?
    var unsetConfigValueHandler: ((String) async throws -> Void)?
    var loadConfigHandler: (() async throws -> OrcConfig)?

    // MARK: - Workspace Management

    var cleanupWorkspaceHandler: ((String) async throws -> Void)?
    var purgeHandler: ((Date?, RunStatus?) async throws -> Void)?

    // MARK: - Protocol Conformance

    func start(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int?
    ) async throws -> Run {
        guard let handler = startHandler else { fatalError("startHandler not set") }
        return try await handler(workflowFile, inputs, maxParallelNodes)
    }

    func startStreaming(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int?
    ) async throws -> AsyncThrowingStream<WorkflowEvent, any Error> {
        if let handler = startStreamingHandler {
            return try await handler(workflowFile, inputs, maxParallelNodes)
        }
        // Fall back: call start() and wrap the result in a single-event stream.
        let run = try await start(workflowFile: workflowFile, inputs: inputs, maxParallelNodes: maxParallelNodes)
        return AsyncThrowingStream { continuation in
            if run.status == .failed {
                continuation.yield(.runFailed(run, error: "Run failed"))
            } else {
                continuation.yield(.runCompleted(run))
            }
            continuation.finish()
        }
    }

    func resume(runID: String) async throws -> Run {
        guard let handler = resumeHandler else { fatalError("resumeHandler not set") }
        return try await handler(runID)
    }

    func cancel(runID: String) async throws {
        guard let handler = cancelHandler else { fatalError("cancelHandler not set") }
        try await handler(runID)
    }

    func respond(runID: String, nodeID: String, response: String) async throws {
        guard let handler = respondHandler else { fatalError("respondHandler not set") }
        try await handler(runID, nodeID, response)
    }

    func listRuns(status: RunStatus?) async throws -> [Run] {
        guard let handler = listRunsHandler else { fatalError("listRunsHandler not set") }
        return try await handler(status)
    }

    func getStatus(runID: String) async throws -> Run? {
        guard let handler = getStatusHandler else { fatalError("getStatusHandler not set") }
        return try await handler(runID)
    }

    func getNodeExecutions(
        runID: String,
        nodeID: String?
    ) async throws -> [NodeExecution] {
        guard let handler = getNodeExecutionsHandler else {
            fatalError("getNodeExecutionsHandler not set")
        }
        return try await handler(runID, nodeID)
    }

    func getLogs(
        runID: String,
        nodeID: String?,
        attempt: Int?,
        iteration: Int?
    ) async throws -> [LogEntry] {
        guard let handler = getLogsHandler else { fatalError("getLogsHandler not set") }
        return try await handler(runID, nodeID, attempt, iteration)
    }

    func getStats() async throws -> [RunStats] {
        guard let handler = getStatsHandler else { fatalError("getStatsHandler not set") }
        return try await handler()
    }

    func catalog() async throws -> Catalog {
        guard let handler = catalogHandler else { fatalError("catalogHandler not set") }
        return try await handler()
    }

    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult) {
        guard let handler = validateHandler else { fatalError("validateHandler not set") }
        return try await handler(workflowFile)
    }

    func getConfigValue(key: String) async throws -> String? {
        guard let handler = getConfigValueHandler else {
            fatalError("getConfigValueHandler not set")
        }
        return try await handler(key)
    }

    func setConfigValue(key: String, value: String) async throws {
        guard let handler = setConfigValueHandler else {
            fatalError("setConfigValueHandler not set")
        }
        try await handler(key, value)
    }

    func unsetConfigValue(key: String) async throws {
        guard let handler = unsetConfigValueHandler else {
            fatalError("unsetConfigValueHandler not set")
        }
        try await handler(key)
    }

    func loadConfig() async throws -> OrcConfig {
        guard let handler = loadConfigHandler else { fatalError("loadConfigHandler not set") }
        return try await handler()
    }

    func cleanupWorkspace(runID: String) async throws {
        guard let handler = cleanupWorkspaceHandler else {
            fatalError("cleanupWorkspaceHandler not set")
        }
        try await handler(runID)
    }

    func purge(olderThan: Date?, status: RunStatus?) async throws {
        guard let handler = purgeHandler else { fatalError("purgeHandler not set") }
        try await handler(olderThan, status)
    }
}
