import Engine
import Foundation
import Models

/// Factory methods for creating test fixture instances with sensible defaults.
///
/// Each factory provides default values for all parameters, so tests only need
/// to specify the fields relevant to the scenario under test.
enum TestFixtures {

    // MARK: - Run

    static func makeRun(
        id: String = "abc12345",
        workflowName: String = "test-workflow",
        workflowFile: String = "test.yaml",
        status: RunStatus = .completed,
        workspacePath: String = "/tmp/workspaces/abc12345",
        inputs: [String: String]? = nil,
        output: String? = nil,
        cleanupPolicy: CleanupPolicy = .never,
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

    // MARK: - NodeExecution

    static func makeNodeExecution(
        id: String = "exec1",
        runID: String = "abc12345",
        nodeID: String = "node1",
        status: NodeStatus = .completed,
        agent: String? = nil,
        attempt: Int = 1,
        iteration: Int = 1,
        prompt: String? = nil,
        message: String? = nil,
        output: String? = nil,
        error: String? = nil,
        tmuxSession: String? = nil,
        startedAt: Date? = Date(),
        completedAt: Date? = Date()
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
            message: message,
            output: output,
            error: error,
            tmuxSession: tmuxSession,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    // MARK: - Workflow

    static func makeWorkflow(
        name: String = "test-workflow",
        description: String? = nil,
        nodeCount: Int = 2,
        inputCount: Int = 1,
        output: [String: String]? = nil,
        cleanupPolicy: CleanupPolicy = .never
    ) -> Workflow {
        let nodes = (0..<nodeCount).map { i in
            Node(
                id: "node\(i)",
                agent: "shell",
                prompt: "echo hello"
            )
        }
        let inputs = (0..<inputCount).map { i in
            WorkflowInput(name: "input\(i)", type: "string", required: true)
        }
        return Workflow(
            name: name,
            description: description,
            input: inputs,
            nodes: nodes,
            output: output,
            cleanupPolicy: cleanupPolicy
        )
    }

    // MARK: - LogEntry

    static func makeLogEntry(
        id: Int? = nil,
        nodeExecutionID: String = "exec1",
        stream: LogStream = .stdout,
        filePath: String = "/tmp/logs/exec1-stdout.log",
        timestamp: Date = Date()
    ) -> LogEntry {
        LogEntry(
            id: id,
            nodeExecutionID: nodeExecutionID,
            stream: stream,
            filePath: filePath,
            timestamp: timestamp
        )
    }

    // MARK: - RunStats

    static func makeRunStats(
        id: Int? = nil,
        runID: String = "abc12345",
        workflowName: String = "test-workflow",
        status: RunStatus = .completed,
        nodeCount: Int = 3,
        durationSeconds: Double? = 12.5,
        completedAt: Date = Date()
    ) -> RunStats {
        RunStats(
            id: id,
            runID: runID,
            workflowName: workflowName,
            status: status,
            nodeCount: nodeCount,
            durationSeconds: durationSeconds,
            completedAt: completedAt
        )
    }

    // MARK: - ValidationResult

    static func makeValidationResult(
        errors: [ValidationError] = [],
        warnings: [ValidationError] = []
    ) -> ValidationResult {
        ValidationResult(errors: errors, warnings: warnings)
    }
}
