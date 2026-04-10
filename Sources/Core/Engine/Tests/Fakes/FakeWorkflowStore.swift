import Foundation
import Models

/// In-memory implementation of WorkflowStoring for testing.
///
/// Stores all data in arrays, providing the same semantics as the real
/// SQLite-backed store but without any database dependencies.
actor FakeWorkflowStore: WorkflowStoring {
    var runs: [Run] = []
    var nodeExecutions: [NodeExecution] = []
    var logEntries: [LogEntry] = []
    var stats: [RunStats] = []

    private var idCounter = 0

    private func nextID() -> String {
        idCounter += 1
        return "fake-\(idCounter)"
    }

    // MARK: - Runs

    func createRun(_ run: Run) async throws -> Run {
        let runID = run.id.isEmpty ? nextID() : run.id
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
        runs.append(newRun)
        return newRun
    }

    func getRun(id: String) async throws -> Run? {
        runs.first { $0.id == id }
    }

    func updateRunStatus(id: String, status: RunStatus) async throws {
        guard let index = runs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let old = runs[index]
        runs[index] = Run(
            id: old.id,
            workflowName: old.workflowName,
            workflowFile: old.workflowFile,
            status: status,
            workspacePath: old.workspacePath,
            inputs: old.inputs,
            output: old.output,
            cleanupPolicy: old.cleanupPolicy,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }

    func updateRunWorkspacePath(id: String, workspacePath: String) async throws {
        guard let index = runs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let old = runs[index]
        runs[index] = Run(
            id: old.id,
            workflowName: old.workflowName,
            workflowFile: old.workflowFile,
            status: old.status,
            workspacePath: workspacePath,
            inputs: old.inputs,
            output: old.output,
            cleanupPolicy: old.cleanupPolicy,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }

    func updateRunOutput(id: String, output: String) async throws {
        guard let index = runs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let old = runs[index]
        runs[index] = Run(
            id: old.id,
            workflowName: old.workflowName,
            workflowFile: old.workflowFile,
            status: old.status,
            workspacePath: old.workspacePath,
            inputs: old.inputs,
            output: output,
            cleanupPolicy: old.cleanupPolicy,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }

    func listRuns(status: RunStatus?) async throws -> [Run] {
        if let status = status {
            return runs.filter { $0.status == status }
        }
        return runs
    }

    func deleteRuns(olderThan date: Date, status: RunStatus?) async throws {
        runs.removeAll { run in
            let matchesDate = run.updatedAt < date
            let matchesStatus = status == nil || run.status == status
            return matchesDate && matchesStatus
        }
    }

    // MARK: - Node Executions

    func createNodeExecution(_ execution: NodeExecution) async throws -> NodeExecution {
        let execID = execution.id.isEmpty ? nextID() : execution.id
        let newExec = NodeExecution(
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
        nodeExecutions.append(newExec)
        return newExec
    }

    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] {
        nodeExecutions.filter { exec in
            exec.runID == runID && (nodeID == nil || exec.nodeID == nodeID)
        }
    }

    func updateNodeExecution(
        id: String,
        status: NodeStatus?,
        output: String?,
        error: String?
    ) async throws {
        guard let index = nodeExecutions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let old = nodeExecutions[index]
        nodeExecutions[index] = NodeExecution(
            id: old.id,
            runID: old.runID,
            nodeID: old.nodeID,
            status: status ?? old.status,
            agent: old.agent,
            attempt: old.attempt,
            iteration: old.iteration,
            prompt: old.prompt,
            message: old.message,
            output: output ?? old.output,
            error: error ?? old.error,
            tmuxSession: old.tmuxSession,
            startedAt: old.startedAt,
            completedAt: (status == .completed || status == .failed) ? Date() : old.completedAt
        )
    }

    func getAwaitingInput(runID: String) async throws -> [NodeExecution] {
        nodeExecutions.filter {
            $0.runID == runID && $0.status == .awaitingInput
        }
    }

    // MARK: - Logs

    func createLogEntry(
        nodeExecutionID: String,
        stream: LogStream,
        filePath: String
    ) async throws {
        let entry = LogEntry(
            nodeExecutionID: nodeExecutionID,
            stream: stream,
            filePath: filePath
        )
        logEntries.append(entry)
    }

    func getLogEntries(nodeExecutionID: String) async throws -> [LogEntry] {
        logEntries.filter { $0.nodeExecutionID == nodeExecutionID }
    }

    // MARK: - Stats

    func recordStats(run: Run, nodeCount: Int, duration: Double) async throws {
        let stat = RunStats(
            runID: run.id,
            workflowName: run.workflowName,
            status: run.status,
            nodeCount: nodeCount,
            durationSeconds: duration
        )
        stats.append(stat)
    }

    func getStats() async throws -> [RunStats] {
        stats
    }

    // MARK: - Lifecycle

    func runRetentionPurge(retentionDays: Int, status: RunStatus?) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
        try await deleteRuns(olderThan: cutoff, status: status)
    }
}
