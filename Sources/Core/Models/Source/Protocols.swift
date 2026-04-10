import Foundation

// MARK: - AgentProviding

/// Abstraction over different agent backends (Claude Code, shell, custom CLIs).
/// Each implementation knows how to execute prompts and manage interactive sessions.
public protocol AgentProviding: Sendable {
    var name: String { get }
    func execute(prompt: String, context: TaskContext, timeout: Int?) async throws -> TaskOutput
    func executeInteractive(prompt: String, context: TaskContext, sessionName: String, timeout: Int?) async throws -> TaskOutput
}

// MARK: - WorkflowStoring

/// Persistence layer for runs, node executions, logs, and stats.
/// Implementations back this with SQLite (via GRDB) in WAL mode.
public protocol WorkflowStoring: Sendable {
    // Runs
    func createRun(_ run: Run) async throws -> Run
    func getRun(id: String) async throws -> Run?
    func updateRunStatus(id: String, status: RunStatus) async throws
    func updateRunOutput(id: String, output: String) async throws
    func updateRunWorkspacePath(id: String, workspacePath: String) async throws
    func listRuns(status: RunStatus?) async throws -> [Run]
    func deleteRuns(olderThan: Date, status: RunStatus?) async throws

    // Node executions
    func createNodeExecution(_ execution: NodeExecution) async throws -> NodeExecution
    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution]
    func updateNodeExecution(id: String, status: NodeStatus?, output: String?, error: String?) async throws
    func getAwaitingInput(runID: String) async throws -> [NodeExecution]

    // Logs
    func createLogEntry(nodeExecutionID: String, stream: LogStream, filePath: String) async throws
    func getLogEntries(nodeExecutionID: String) async throws -> [LogEntry]

    // Stats
    func recordStats(run: Run, nodeCount: Int, duration: Double) async throws
    func getStats() async throws -> [RunStats]

    // Lifecycle
    func runRetentionPurge(retentionDays: Int, status: RunStatus?) async throws
}

// MARK: - TemplateResolving

/// Resolves `{{variable}}` placeholders in prompt strings using the current task context.
public protocol TemplateResolving: Sendable {
    func resolve(template: String, context: TaskContext) throws -> String
}

// MARK: - ExpressionEvaluating

/// Evaluates boolean `when:` expressions to determine whether a node should execute.
public protocol ExpressionEvaluating: Sendable {
    func evaluate(expression: String, context: TaskContext) throws -> Bool
}

// MARK: - WorkflowParsing

/// Parses YAML workflow definitions into validated `Workflow` models.
public protocol WorkflowParsing: Sendable {
    func parse(yaml: String) throws -> Workflow
    func parse(file: String) throws -> Workflow
    func validate(workflow: Workflow) -> ValidationResult
}

// MARK: - ProcessRunning

/// Runs subprocesses with captured output and optional timeout.
public protocol ProcessRunning: Sendable {
    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?
    ) async throws -> ProcessResult
}

// MARK: - TmuxProviding

/// Manages tmux sessions for interactive agent nodes.
public protocol TmuxProviding: Sendable {
    func createSession(name: String, command: String, workingDirectory: String?) async throws
    func destroySession(name: String) async throws
    func captureOutput(name: String) async throws -> String
    func sessionExists(name: String) async throws -> Bool
    func isAvailable() async -> Bool
}

// MARK: - EvaluatorProviding

/// Evaluates named evaluators (AI, script, or sub-workflow) to produce a boolean outcome.
public protocol EvaluatorProviding: Sendable {
    func evaluate(name: String, lastOutput: String, context: TaskContext) async throws -> Bool
}
