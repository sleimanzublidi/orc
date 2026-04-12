import Foundation
import Models

/// Protocol matching `WorkflowEngine`'s public API, enabling mock injection
/// for command tests.
///
/// Commands depend on this protocol rather than the concrete actor, so tests
/// can supply a lightweight mock without standing up SQLite, providers, etc.
///
/// All methods that are actor-isolated on `WorkflowEngine` are declared
/// `async` here. Synchronous actor-isolated methods (e.g. `validate`,
/// config accessors) become `async throws` in the protocol because callers
/// must hop into the actor to invoke them.
public protocol OrcEngineProviding: Sendable {

    // MARK: - Core Operations

    func start(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int?
    ) async throws -> Run

    func startStreaming(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int?
    ) async throws -> AsyncThrowingStream<WorkflowEvent, any Error>

    func resume(runID: String) async throws -> Run

    func cancel(runID: String) async throws

    func respond(runID: String, nodeID: String, response: String) async throws

    // MARK: - Queries

    func listRuns(status: RunStatus?) async throws -> [Run]

    func getStatus(runID: String) async throws -> Run?

    func getNodeExecutions(
        runID: String,
        nodeID: String?
    ) async throws -> [NodeExecution]

    func getLogs(
        runID: String,
        nodeID: String?,
        attempt: Int?,
        iteration: Int?
    ) async throws -> [LogEntry]

    func getStats() async throws -> [RunStats]

    func catalog() async throws -> Catalog

    // MARK: - Validation

    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult)

    // MARK: - Configuration

    func getConfigValue(key: String) async throws -> String?

    func setConfigValue(key: String, value: String) async throws

    func unsetConfigValue(key: String) async throws

    func loadConfig() async throws -> OrcConfig

    // MARK: - Workspace Management

    func cleanupWorkspace(runID: String) async throws

    func purge(olderThan: Date?, status: RunStatus?) async throws

    // MARK: - Properties

    var basePath: String { get }
}

// MARK: - Default Streaming Implementation

/// Provides a fallback `startStreaming()` for conformers that only implement
/// `start()`. Calls `start()` and wraps the resulting `Run` in a single-event
/// stream. Real streaming (with per-node events) requires the concrete
/// `WorkflowEngine` implementation.
extension OrcEngineProviding {
    public func startStreaming(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int? = nil
    ) async throws -> AsyncThrowingStream<WorkflowEvent, any Error> {
        let run = try await self.start(
            workflowFile: workflowFile,
            inputs: inputs,
            maxParallelNodes: maxParallelNodes
        )
        return AsyncThrowingStream { continuation in
            if run.status == .failed {
                continuation.yield(.runFailed(run, error: "Run failed"))
            } else {
                continuation.yield(.runCompleted(run))
            }
            continuation.finish()
        }
    }
}

// MARK: - WorkflowEngine Conformance

/// `WorkflowEngine` already implements every method in this protocol.
///
/// Actor-isolated synchronous methods (`validate`, config accessors)
/// satisfy the `async` protocol requirements because Swift automatically
/// makes actor-isolated calls asynchronous from outside the actor.
///
/// `basePath` is `nonisolated` on `WorkflowEngine`, so it satisfies
/// the synchronous property requirement directly.
extension WorkflowEngine: OrcEngineProviding {}
