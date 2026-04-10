import Foundation
import GRDB
import Models

/// SQLite-backed persistence layer for workflow runs, node executions, logs, and stats.
///
/// Uses GRDB's `DatabasePool` for file-backed databases, enabling concurrent reads
/// via WAL mode while the actor serializes writes. For in-memory testing, a
/// `DatabaseQueue` is accepted (DatabasePool does not support in-memory databases).
/// Both conform to `DatabaseWriter`, which is the stored property type.
actor WorkflowStore: WorkflowStoring {
    private let db: any DatabaseWriter

    // Characters used for generating 8-char alphanumeric run IDs
    private static let idCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let idLength = 8

    /// Opens or creates a database at the given file path using `DatabasePool` for
    /// concurrent read access via WAL mode, and runs migrations.
    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        self.db = pool
        try MigrationManager.migrate(pool)
    }

    /// Creates a store backed by the given DatabaseQueue (useful for in-memory testing).
    /// `DatabasePool` does not support in-memory databases, so tests pass a `DatabaseQueue`.
    /// Foreign keys are enabled on the single connection that DatabaseQueue maintains.
    init(db: DatabaseQueue) throws {
        self.db = db
        // DatabaseQueue uses a single persistent connection, so setting the PRAGMA
        // once is sufficient for the lifetime of this queue.
        try db.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try MigrationManager.migrate(db)
    }

    // MARK: - ID Generation

    /// Generates a random 8-character alphanumeric ID.
    ///
    /// `idCharacters` is a non-empty static array, so `randomElement()` will
    /// never return nil. The guard is a safety net against future changes.
    private static func generateID() -> String {
        String((0..<idLength).compactMap { _ in idCharacters.randomElement() })
    }

    // MARK: - Runs

    func createRun(_ run: Run) async throws -> Run {
        // Generate an ID if the provided one is empty
        let runID = run.id.isEmpty ? Self.generateID() : run.id
        let newRun = Run(
            id: runID,
            workflowName: run.workflowName,
            workflowFile: run.workflowFile,
            status: run.status,
            workspacePath: run.workspacePath,
            inputs: run.inputs,
            output: run.output,
            cleanupPolicy: run.cleanupPolicy,
            createdAt: run.createdAt,
            updatedAt: run.updatedAt
        )
        try await db.write { db in
            try newRun.insert(db)
        }
        return newRun
    }

    func getRun(id: String) async throws -> Run? {
        try await db.read { db in
            try Run.fetchOne(db, key: id)
        }
    }

    func updateRunStatus(id: String, status: RunStatus) async throws {
        try await db.write { db in
            guard let run = try Run.fetchOne(db, key: id) else {
                throw StoreError.recordNotFound(table: "runs", id: id)
            }
            // Rebuild with updated status and timestamp
            let updated = Run(
                id: run.id,
                workflowName: run.workflowName,
                workflowFile: run.workflowFile,
                status: status,
                workspacePath: run.workspacePath,
                inputs: run.inputs,
                output: run.output,
                cleanupPolicy: run.cleanupPolicy,
                createdAt: run.createdAt,
                updatedAt: Date()
            )
            try updated.update(db)
        }
    }

    func updateRunWorkspacePath(id: String, workspacePath: String) async throws {
        try await db.write { db in
            guard let run = try Run.fetchOne(db, key: id) else {
                throw StoreError.recordNotFound(table: "runs", id: id)
            }
            let updated = Run(
                id: run.id,
                workflowName: run.workflowName,
                workflowFile: run.workflowFile,
                status: run.status,
                workspacePath: workspacePath,
                inputs: run.inputs,
                output: run.output,
                cleanupPolicy: run.cleanupPolicy,
                createdAt: run.createdAt,
                updatedAt: Date()
            )
            try updated.update(db)
        }
    }

    func updateRunOutput(id: String, output: String) async throws {
        try await db.write { db in
            guard let run = try Run.fetchOne(db, key: id) else {
                throw StoreError.recordNotFound(table: "runs", id: id)
            }
            let updated = Run(
                id: run.id,
                workflowName: run.workflowName,
                workflowFile: run.workflowFile,
                status: run.status,
                workspacePath: run.workspacePath,
                inputs: run.inputs,
                output: output,
                cleanupPolicy: run.cleanupPolicy,
                createdAt: run.createdAt,
                updatedAt: Date()
            )
            try updated.update(db)
        }
    }

    func listRuns(status: RunStatus?) async throws -> [Run] {
        try await db.read { db in
            if let status = status {
                return try Run
                    .filter(Column("status") == status.rawValue)
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            } else {
                return try Run
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
        }
    }

    func deleteRuns(olderThan date: Date, status: RunStatus?) async throws {
        try await db.write { db in
            // Use updated_at (set on completion/failure) rather than created_at
            // so retention is measured from when the run finished, not when it started.
            var request = Run.filter(Column("updated_at") < date)
            if let status = status {
                request = request.filter(Column("status") == status.rawValue)
            }
            try request.deleteAll(db)
        }
    }

    // MARK: - Node Executions

    func createNodeExecution(_ execution: NodeExecution) async throws -> NodeExecution {
        let execID = execution.id.isEmpty ? Self.generateID() : execution.id
        let newExecution = NodeExecution(
            id: execID,
            runID: execution.runID,
            nodeID: execution.nodeID,
            status: execution.status,
            agent: execution.agent,
            attempt: execution.attempt,
            iteration: execution.iteration,
            prompt: execution.prompt,
            message: execution.message,
            output: execution.output,
            error: execution.error,
            tmuxSession: execution.tmuxSession,
            startedAt: execution.startedAt,
            completedAt: execution.completedAt
        )
        try await db.write { db in
            try newExecution.insert(db)
        }
        return newExecution
    }

    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] {
        try await db.read { db in
            var request = NodeExecution.filter(Column("run_id") == runID)
            if let nodeID = nodeID {
                request = request.filter(Column("node_id") == nodeID)
            }
            return try request
                .order(Column("started_at").asc)
                .fetchAll(db)
        }
    }

    func updateNodeExecution(id: String, status: NodeStatus?, output: String?, error: String?) async throws {
        try await db.write { db in
            guard let execution = try NodeExecution.fetchOne(db, key: id) else {
                throw StoreError.recordNotFound(table: "node_executions", id: id)
            }
            let updated = NodeExecution(
                id: execution.id,
                runID: execution.runID,
                nodeID: execution.nodeID,
                status: status ?? execution.status,
                agent: execution.agent,
                attempt: execution.attempt,
                iteration: execution.iteration,
                prompt: execution.prompt,
                message: execution.message,
                output: output ?? execution.output,
                error: error ?? execution.error,
                tmuxSession: execution.tmuxSession,
                startedAt: execution.startedAt,
                completedAt: status == .completed || status == .failed ? Date() : execution.completedAt
            )
            try updated.update(db)
        }
    }

    func getAwaitingInput(runID: String) async throws -> [NodeExecution] {
        try await db.read { db in
            try NodeExecution
                .filter(Column("run_id") == runID)
                .filter(Column("status") == NodeStatus.awaitingInput.rawValue)
                .fetchAll(db)
        }
    }

    // MARK: - Logs

    func createLogEntry(nodeExecutionID: String, stream: LogStream, filePath: String) async throws {
        let entry = LogEntry(
            nodeExecutionID: nodeExecutionID,
            stream: stream,
            filePath: filePath,
            timestamp: Date()
        )
        try await db.write { db in
            try entry.insert(db)
        }
    }

    func getLogEntries(nodeExecutionID: String) async throws -> [LogEntry] {
        try await db.read { db in
            try LogEntry
                .filter(Column("node_execution_id") == nodeExecutionID)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Stats

    func recordStats(run: Run, nodeCount: Int, duration: Double) async throws {
        let stats = RunStats(
            runID: run.id,
            workflowName: run.workflowName,
            status: run.status,
            nodeCount: nodeCount,
            durationSeconds: duration,
            completedAt: Date()
        )
        try await db.write { db in
            try stats.insert(db)
        }
    }

    func getStats() async throws -> [RunStats] {
        try await db.read { db in
            try RunStats
                .order(Column("completed_at").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Lifecycle

    func runRetentionPurge(retentionDays: Int, status: RunStatus?) async throws {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            throw StoreError.internalError(detail: "Failed to compute retention cutoff date for \(retentionDays) days")
        }
        try await deleteRuns(olderThan: cutoff, status: status)
    }
}

// MARK: - Factory

/// Factory for creating `WorkflowStoring` instances.
///
/// The concrete `WorkflowStore` actor is `internal`; callers across module
/// boundaries access it through this factory and the `WorkflowStoring` protocol.
public enum StoreFactory {
    /// Creates a file-backed store at the given path using WAL mode.
    public static func makeStore(path: String) throws -> any WorkflowStoring {
        try WorkflowStore(path: path)
    }

    /// Creates a store backed by an in-memory `DatabaseQueue` (for testing).
    public static func makeStore(db: DatabaseQueue) throws -> any WorkflowStoring {
        try WorkflowStore(db: db)
    }
}
