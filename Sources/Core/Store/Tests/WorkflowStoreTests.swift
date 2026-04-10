import Foundation
import GRDB
import Models
import Testing

@testable import Store

// MARK: - Test Helpers

/// Creates an in-memory WorkflowStore for testing (no disk I/O).
private func makeStore() throws -> WorkflowStore {
    try WorkflowStore(db: DatabaseQueue())
}

/// Creates a minimal Run for testing with sensible defaults.
private func makeTestRun(
    id: String = "test1234",
    workflowName: String = "build-pipeline",
    workflowFile: String = "build.yaml",
    status: RunStatus = .pending,
    workspacePath: String = "/tmp/orc/test",
    inputs: [String: String]? = nil,
    output: String? = nil,
    cleanupPolicy: CleanupPolicy = .duration(days: 30),
    createdAt: Date = Date(),
    updatedAt: Date = Date()
) -> Run {
    Run(
        id: id,
        workflowName: workflowName,
        workflowFile: workflowFile,
        status: status,
        workspacePath: workspacePath,
        inputs: inputs,
        output: output,
        cleanupPolicy: cleanupPolicy,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

/// Creates a minimal NodeExecution for testing with sensible defaults.
private func makeTestNodeExecution(
    id: String = "exec1234",
    runID: String = "test1234",
    nodeID: String = "compile",
    status: NodeStatus = .pending,
    agent: String? = "claude-code",
    attempt: Int = 1,
    iteration: Int = 1,
    prompt: String? = "Build the project",
    output: String? = nil,
    error: String? = nil
) -> NodeExecution {
    NodeExecution(
        id: id,
        runID: runID,
        nodeID: nodeID,
        status: status,
        agent: agent,
        attempt: attempt,
        iteration: iteration,
        prompt: prompt,
        output: output,
        error: error,
        startedAt: Date(),
        completedAt: nil
    )
}

// MARK: - Migration Tests

@Suite("Migration Tests")
struct MigrationTests {
    @Test("Tables exist after initialization")
    func tablesExistAfterInit() async throws {
        let store = try makeStore()

        // Access the database directly to verify tables exist.
        // We use the store's protocol methods as a proxy: if they work, the tables exist.
        // Additionally, we can verify by listing runs (which queries the runs table).
        let runs = try await store.listRuns(status: nil)
        #expect(runs.isEmpty)

        let stats = try await store.getStats()
        #expect(stats.isEmpty)
    }
}

// MARK: - Run CRUD Tests

@Suite("Run CRUD Tests")
struct RunCRUDTests {
    @Test("Create and retrieve a run")
    func createAndGetRun() async throws {
        let store = try makeStore()
        let run = makeTestRun(inputs: ["env": "staging"])

        let created = try await store.createRun(run)
        #expect(created.id == "test1234")
        #expect(created.workflowName == "build-pipeline")
        #expect(created.inputs?["env"] == "staging")

        let fetched = try await store.getRun(id: "test1234")
        #expect(fetched != nil)
        #expect(fetched?.workflowName == "build-pipeline")
        #expect(fetched?.status == .pending)
        #expect(fetched?.inputs?["env"] == "staging")
    }

    @Test("Get nonexistent run returns nil")
    func getNonexistentRun() async throws {
        let store = try makeStore()
        let result = try await store.getRun(id: "doesNotExist")
        #expect(result == nil)
    }

    @Test("Update run status")
    func updateRunStatus() async throws {
        let store = try makeStore()
        let run = makeTestRun()
        _ = try await store.createRun(run)

        try await store.updateRunStatus(id: "test1234", status: .running)

        let fetched = try await store.getRun(id: "test1234")
        #expect(fetched?.status == .running)
    }

    @Test("Update run status for nonexistent run throws error")
    func updateNonexistentRunStatus() async throws {
        let store = try makeStore()

        await #expect(throws: StoreError.recordNotFound(table: "runs", id: "missing")) {
            try await store.updateRunStatus(id: "missing", status: .running)
        }
    }

    @Test("Update run output")
    func updateRunOutput() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())

        try await store.updateRunOutput(id: "test1234", output: "Build succeeded")

        let fetched = try await store.getRun(id: "test1234")
        #expect(fetched?.output == "Build succeeded")
    }

    @Test("Update run output for nonexistent run throws error")
    func updateNonexistentRunOutput() async throws {
        let store = try makeStore()

        await #expect(throws: StoreError.recordNotFound(table: "runs", id: "nope")) {
            try await store.updateRunOutput(id: "nope", output: "data")
        }
    }

    @Test("List runs without filter")
    func listAllRuns() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun(id: "run00001", status: .pending))
        _ = try await store.createRun(makeTestRun(id: "run00002", status: .completed))
        _ = try await store.createRun(makeTestRun(id: "run00003", status: .failed))

        let all = try await store.listRuns(status: nil)
        #expect(all.count == 3)
    }

    @Test("List runs with status filter")
    func listRunsWithFilter() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun(id: "run00001", status: .pending))
        _ = try await store.createRun(makeTestRun(id: "run00002", status: .completed))
        _ = try await store.createRun(makeTestRun(id: "run00003", status: .failed))

        let completed = try await store.listRuns(status: .completed)
        #expect(completed.count == 1)
        #expect(completed[0].id == "run00002")
    }

    @Test("Cleanup policy round-trips correctly")
    func cleanupPolicyRoundTrip() async throws {
        let store = try makeStore()

        // Test various cleanup policies
        _ = try await store.createRun(makeTestRun(id: "run_dur", cleanupPolicy: .duration(days: 7)))
        _ = try await store.createRun(makeTestRun(id: "run_suc", cleanupPolicy: .onSuccess))
        _ = try await store.createRun(makeTestRun(id: "run_alw", cleanupPolicy: .always))
        _ = try await store.createRun(makeTestRun(id: "run_nev", cleanupPolicy: .never))

        let dur = try await store.getRun(id: "run_dur")
        #expect(dur?.cleanupPolicy == .duration(days: 7))

        let suc = try await store.getRun(id: "run_suc")
        #expect(suc?.cleanupPolicy == .onSuccess)

        let alw = try await store.getRun(id: "run_alw")
        #expect(alw?.cleanupPolicy == .always)

        let nev = try await store.getRun(id: "run_nev")
        #expect(nev?.cleanupPolicy == .never)
    }

    @Test("Create run with empty ID generates one")
    func createRunGeneratesID() async throws {
        let store = try makeStore()
        let run = makeTestRun(id: "")

        let created = try await store.createRun(run)
        #expect(!created.id.isEmpty)
        #expect(created.id.count == 8)

        // Verify it's stored
        let fetched = try await store.getRun(id: created.id)
        #expect(fetched != nil)
    }
}

// MARK: - Node Execution Tests

@Suite("Node Execution Tests")
struct NodeExecutionTests {
    @Test("Create and retrieve node execution")
    func createAndGetNodeExecution() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())

        let exec = makeTestNodeExecution()
        let created = try await store.createNodeExecution(exec)
        #expect(created.id == "exec1234")
        #expect(created.nodeID == "compile")

        let fetched = try await store.getNodeExecutions(runID: "test1234", nodeID: nil)
        #expect(fetched.count == 1)
        #expect(fetched[0].nodeID == "compile")
        #expect(fetched[0].agent == "claude-code")
    }

    @Test("Get node executions filtered by nodeID")
    func getNodeExecutionsByNodeID() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())

        _ = try await store.createNodeExecution(makeTestNodeExecution(id: "e1", nodeID: "compile"))
        _ = try await store.createNodeExecution(makeTestNodeExecution(id: "e2", nodeID: "test"))
        _ = try await store.createNodeExecution(makeTestNodeExecution(id: "e3", nodeID: "compile"))

        let compileExecs = try await store.getNodeExecutions(runID: "test1234", nodeID: "compile")
        #expect(compileExecs.count == 2)

        let testExecs = try await store.getNodeExecutions(runID: "test1234", nodeID: "test")
        #expect(testExecs.count == 1)
    }

    @Test("Update node execution status and output")
    func updateNodeExecution() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())
        _ = try await store.createNodeExecution(makeTestNodeExecution())

        try await store.updateNodeExecution(
            id: "exec1234",
            status: .completed,
            output: "All tests passed",
            error: nil
        )

        let fetched = try await store.getNodeExecutions(runID: "test1234", nodeID: nil)
        #expect(fetched[0].status == .completed)
        #expect(fetched[0].output == "All tests passed")
        #expect(fetched[0].completedAt != nil)
    }

    @Test("Update node execution with error")
    func updateNodeExecutionWithError() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())
        _ = try await store.createNodeExecution(makeTestNodeExecution())

        try await store.updateNodeExecution(
            id: "exec1234",
            status: .failed,
            output: nil,
            error: "Compilation error on line 42"
        )

        let fetched = try await store.getNodeExecutions(runID: "test1234", nodeID: nil)
        #expect(fetched[0].status == .failed)
        #expect(fetched[0].error == "Compilation error on line 42")
    }

    @Test("Update nonexistent node execution throws error")
    func updateNonexistentNodeExecution() async throws {
        let store = try makeStore()

        await #expect(throws: StoreError.recordNotFound(table: "node_executions", id: "ghost")) {
            try await store.updateNodeExecution(id: "ghost", status: .completed, output: nil, error: nil)
        }
    }

    @Test("Get awaiting input nodes")
    func getAwaitingInput() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())

        _ = try await store.createNodeExecution(
            makeTestNodeExecution(id: "e1", nodeID: "step1", status: .completed)
        )
        _ = try await store.createNodeExecution(
            makeTestNodeExecution(id: "e2", nodeID: "step2", status: .awaitingInput)
        )
        _ = try await store.createNodeExecution(
            makeTestNodeExecution(id: "e3", nodeID: "step3", status: .running)
        )

        let awaiting = try await store.getAwaitingInput(runID: "test1234")
        #expect(awaiting.count == 1)
        #expect(awaiting[0].nodeID == "step2")
    }

    @Test("Create node execution with empty ID generates one")
    func createNodeExecutionGeneratesID() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())

        let exec = makeTestNodeExecution(id: "")
        let created = try await store.createNodeExecution(exec)
        #expect(!created.id.isEmpty)
        #expect(created.id.count == 8)
    }
}

// MARK: - Log Entry Tests

@Suite("Log Entry Tests")
struct LogEntryTests {
    @Test("Create and retrieve log entries")
    func createAndGetLogEntries() async throws {
        let store = try makeStore()
        _ = try await store.createRun(makeTestRun())
        _ = try await store.createNodeExecution(makeTestNodeExecution())

        try await store.createLogEntry(
            nodeExecutionID: "exec1234",
            stream: .stdout,
            filePath: "/tmp/orc/logs/stdout.log"
        )
        try await store.createLogEntry(
            nodeExecutionID: "exec1234",
            stream: .stderr,
            filePath: "/tmp/orc/logs/stderr.log"
        )

        let logs = try await store.getLogEntries(nodeExecutionID: "exec1234")
        #expect(logs.count == 2)
        #expect(logs[0].stream == .stdout)
        #expect(logs[1].stream == .stderr)
        #expect(logs[0].filePath == "/tmp/orc/logs/stdout.log")
    }

    @Test("Log entries for nonexistent node execution returns empty")
    func logEntriesForMissingNode() async throws {
        let store = try makeStore()
        let logs = try await store.getLogEntries(nodeExecutionID: "nonexistent")
        #expect(logs.isEmpty)
    }
}

// MARK: - Stats Tests

@Suite("Stats Tests")
struct StatsTests {
    @Test("Record and retrieve stats")
    func recordAndGetStats() async throws {
        let store = try makeStore()
        let run = makeTestRun(status: .completed)
        let created = try await store.createRun(run)

        try await store.recordStats(run: created, nodeCount: 5, duration: 12.5)

        let stats = try await store.getStats()
        #expect(stats.count == 1)
        #expect(stats[0].runID == "test1234")
        #expect(stats[0].workflowName == "build-pipeline")
        #expect(stats[0].status == .completed)
        #expect(stats[0].nodeCount == 5)
        #expect(stats[0].durationSeconds == 12.5)
    }

    @Test("Stats survive purge")
    func statsSurvivePurge() async throws {
        let store = try makeStore()

        // Create a run with an old date
        let oldDate = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
        let run = makeTestRun(status: .completed, createdAt: oldDate, updatedAt: oldDate)
        let created = try await store.createRun(run)

        // Record stats for that run
        try await store.recordStats(run: created, nodeCount: 3, duration: 8.0)

        // Purge old runs
        try await store.deleteRuns(olderThan: Date(), status: nil)

        // Run should be deleted
        let fetchedRun = try await store.getRun(id: "test1234")
        #expect(fetchedRun == nil)

        // Stats should still exist
        let stats = try await store.getStats()
        #expect(stats.count == 1)
        #expect(stats[0].runID == "test1234")
    }
}

// MARK: - Purge Tests

@Suite("Purge Tests")
struct PurgeTests {
    @Test("Delete runs older than cutoff")
    func deleteOldRuns() async throws {
        let store = try makeStore()

        let oldDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let recentDate = Date()

        _ = try await store.createRun(makeTestRun(id: "old_run1", createdAt: oldDate, updatedAt: oldDate))
        _ = try await store.createRun(makeTestRun(id: "new_run1", createdAt: recentDate, updatedAt: recentDate))

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        try await store.deleteRuns(olderThan: cutoff, status: nil)

        let remaining = try await store.listRuns(status: nil)
        #expect(remaining.count == 1)
        #expect(remaining[0].id == "new_run1")
    }

    @Test("Delete runs with status filter")
    func deleteRunsWithStatusFilter() async throws {
        let store = try makeStore()

        let oldDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!

        _ = try await store.createRun(
            makeTestRun(id: "old_done", status: .completed, createdAt: oldDate, updatedAt: oldDate)
        )
        _ = try await store.createRun(
            makeTestRun(id: "old_fail", status: .failed, createdAt: oldDate, updatedAt: oldDate)
        )

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        try await store.deleteRuns(olderThan: cutoff, status: .completed)

        let remaining = try await store.listRuns(status: nil)
        #expect(remaining.count == 1)
        #expect(remaining[0].id == "old_fail")
    }

    @Test("Cascade deletes node executions and logs")
    func cascadeDelete() async throws {
        let store = try makeStore()

        let oldDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        _ = try await store.createRun(makeTestRun(id: "cascade1", createdAt: oldDate, updatedAt: oldDate))
        _ = try await store.createNodeExecution(
            makeTestNodeExecution(id: "cexec1", runID: "cascade1")
        )
        try await store.createLogEntry(
            nodeExecutionID: "cexec1",
            stream: .stdout,
            filePath: "/tmp/log"
        )

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        try await store.deleteRuns(olderThan: cutoff, status: nil)

        // Run gone
        let run = try await store.getRun(id: "cascade1")
        #expect(run == nil)

        // Node executions gone
        let execs = try await store.getNodeExecutions(runID: "cascade1", nodeID: nil)
        #expect(execs.isEmpty)

        // Logs gone
        let logs = try await store.getLogEntries(nodeExecutionID: "cexec1")
        #expect(logs.isEmpty)
    }

    @Test("Retention purge uses day calculation")
    func retentionPurge() async throws {
        let store = try makeStore()

        let oldDate = Calendar.current.date(byAdding: .day, value: -45, to: Date())!
        _ = try await store.createRun(makeTestRun(id: "aged_run", createdAt: oldDate, updatedAt: oldDate))
        _ = try await store.createRun(makeTestRun(id: "fresh_run"))

        try await store.runRetentionPurge(retentionDays: 30, status: nil)

        let remaining = try await store.listRuns(status: nil)
        #expect(remaining.count == 1)
        #expect(remaining[0].id == "fresh_run")
    }
}
