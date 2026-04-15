import Foundation

// MARK: - AgentProviding

/// Abstraction over different agent backends (Claude Code, shell, custom CLIs).
/// Each implementation knows how to execute prompts and manage interactive sessions.
public protocol AgentProviding: Sendable {
    var name: String { get }
    func execute(prompt: String, context: TaskContext, timeout: Int?, parameters: [String: String]) async throws -> TaskOutput
    func executeInteractive(prompt: String, context: TaskContext, sessionName: String, timeout: Int?) async throws -> TaskOutput
    func executeStreaming(
        prompt: String,
        context: TaskContext,
        timeout: Int?,
        parameters: [String: String]
    ) -> AsyncThrowingStream<AgentStreamEvent, any Error>
}

// MARK: - AgentProviding Streaming Default

extension AgentProviding {
    public func executeStreaming(
        prompt: String,
        context: TaskContext,
        timeout: Int? = nil,
        parameters: [String: String] = [:]
    ) -> AsyncThrowingStream<AgentStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await self.execute(
                        prompt: prompt, context: context,
                        timeout: timeout, parameters: parameters
                    )
                    continuation.yield(.completed(output))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
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
    func listRuns(status: RunStatus?, topLevelOnly: Bool) async throws -> [Run]
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

    /// Resolves a `Resolvable<T>` value against the given context.
    ///
    /// For `.literal` values, returns the value directly. For `.template`
    /// expressions, resolves the template string and converts the result
    /// to `T` via `ResolvableConvertible.fromResolved(_:)`.
    func resolve<T: ResolvableConvertible>(_ resolvable: Resolvable<T>, context: TaskContext) throws -> T
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
///
/// When `executablePath` is non-nil, the process is launched directly using
/// that path as the executable and `arguments` as its argv — no shell wrapping.
/// When `executablePath` is nil (the default), the `command` string is executed
/// via the platform default shell's `-c` flag (legacy shell-based mode).
///
/// Prefer `executablePath` for known binaries to avoid shell-string injection.
/// Use the shell-based mode only for user-supplied shell commands that need
/// shell features (pipes, redirects, variable expansion, etc.).
public protocol ProcessRunning: Sendable {
    /// - Parameters:
    ///   - command: In shell mode (executablePath nil), the shell command string.
    ///     In direct mode (executablePath non-nil), used only for error messages/diagnostics.
    ///   - arguments: In shell mode, unused. In direct mode, passed as process.arguments.
    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?,
        executablePath: String?
    ) async throws -> ProcessResult

    /// Streams process output as it arrives, yielding `.stdout` / `.stderr` chunks
    /// followed by a `.completed` event when the process exits.
    ///
    /// Uses pipes rather than file handles so data is available immediately.
    /// If `stdoutPath` / `stderrPath` are provided, chunks are also written to
    /// log files on disk (preserving the same log infrastructure as `run()`).
    func runStreaming(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?,
        executablePath: String?
    ) -> AsyncThrowingStream<ProcessStreamEvent, any Error>
}

// MARK: - ProcessRunning Default

extension ProcessRunning {
    /// Default implementation that passes `nil` for `executablePath`,
    /// preserving the legacy shell-based behavior for existing callers.
    public func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?
    ) async throws -> ProcessResult {
        try await run(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            executablePath: nil
        )
    }
}

// MARK: - ProcessRunning Streaming Default

extension ProcessRunning {
    /// Default streaming implementation that wraps a single `run()` call.
    /// Yields the completed result as the only event. Conformers that need
    /// real-time chunk streaming should provide their own implementation.
    public func runStreaming(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?,
        executablePath: String? = nil
    ) -> AsyncThrowingStream<ProcessStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.run(
                        command: command,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        timeout: timeout,
                        stdoutPath: stdoutPath,
                        stderrPath: stderrPath,
                        executablePath: executablePath
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
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
