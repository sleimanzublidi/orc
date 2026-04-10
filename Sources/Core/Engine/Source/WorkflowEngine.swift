import Foundation
import Logging
import Models
import Parser
import Providers
import Store
import Template

/// The main public API actor for executing workflows.
///
/// `WorkflowEngine` is the single entry point for the Orc engine library.
/// It coordinates parsing, planning, dispatching, resuming, and cancelling
/// workflow runs. The CLI is a thin argument-parsing layer over this actor.
///
/// All internal types (NodeDispatcher, LoopHandler, etc.) are `internal` —
/// only WorkflowEngine is public.
public actor WorkflowEngine {
    private let store: any WorkflowStoring
    private let parser: any WorkflowParsing
    private let templateResolver: any TemplateResolving
    private let expressionEvaluator: any ExpressionEvaluating
    private let providers: ProviderRegistry
    private let workspaceManager: WorkspaceManager
    private let configManager: ConfigManager

    private let logger = Logger(label: "orc.engine")

    /// Tracks in-flight dispatch tasks by run ID so `cancel()` can cancel the
    /// Swift Task, which in turn triggers `withTaskCancellationHandler` inside
    /// `ProcessRunner` to SIGTERM running processes.
    private var runningTasks: [String: Task<Run, Error>] = [:]

    // MARK: - Initialization

    /// Creates an engine rooted at the given `.orc` directory.
    ///
    /// Initializes a real SQLite store, parser, template resolver, expression
    /// evaluator, and default provider registry. Loads `.orc/config.yml` to
    /// configure providers: custom CLI agents (type: cli-agent) are created via
    /// `ProviderFactory`, while built-in providers (claude-code, shell)
    /// are configured with any overrides from the config.
    ///
    /// - Parameter basePath: The path to the `.orc` directory.
    public init(basePath: String) async throws {
        let dbPath = (basePath as NSString).appendingPathComponent("orc.db")
        let fm = FileManager.default

        // Ensure .orc directory exists.
        if !fm.fileExists(atPath: basePath) {
            try fm.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        }

        let realStore = try StoreFactory.makeStore(path: dbPath)
        let realParser = ParserFactory.makeParser()
        let realTemplateResolver = makeTemplateResolver()
        let realExpressionEvaluator = makeExpressionEvaluator()

        let manager = ConfigManager(basePath: basePath)
        let config = try manager.loadConfig()

        // Build providers from config, falling back to defaults for shell and claude-code.
        let registry = WorkflowEngine.buildProviderRegistry(from: config)

        self.store = realStore
        self.parser = realParser
        self.templateResolver = realTemplateResolver
        self.expressionEvaluator = realExpressionEvaluator
        self.providers = registry
        self.workspaceManager = WorkspaceManager(basePath: basePath)
        self.configManager = manager

        // Purge expired workspaces on startup — lightweight query before any
        // command executes (design spec: retention-based cleanup).
        try await self.workspaceManager.startupPurge(store: realStore)
    }

    /// Creates an engine with injected dependencies (for testing).
    ///
    /// All dependencies are provided explicitly, allowing fakes to be used in tests.
    public init(
        store: any WorkflowStoring,
        parser: any WorkflowParsing,
        templateResolver: any TemplateResolving,
        expressionEvaluator: any ExpressionEvaluating,
        providers: ProviderRegistry,
        workspaceManager: WorkspaceManager,
        configManager: ConfigManager
    ) {
        self.store = store
        self.parser = parser
        self.templateResolver = templateResolver
        self.expressionEvaluator = expressionEvaluator
        self.providers = providers
        self.workspaceManager = workspaceManager
        self.configManager = configManager
    }

    // MARK: - Provider Registry Construction

    /// Builds a `ProviderRegistry` from the loaded `OrcConfig`.
    ///
    /// For each entry in `config.providers`:
    /// - `claude-code`: creates a claude-code provider with optional `path` override.
    /// - `shell`: creates a shell provider with optional `default_shell` override.
    /// - Entries with `type: "cli-agent"` and a `command`: creates a CLI agent provider.
    ///
    /// If `shell` or `claude-code` are not present in config, default instances are added
    /// so the engine always has these two built-in providers available.
    static func buildProviderRegistry(from config: OrcConfig) -> ProviderRegistry {
        var providerList: [any AgentProviding] = []
        var hasShell = false
        var hasClaude = false

        for (name, providerConfig) in config.providers {
            switch name {
            case "claude-code":
                let path = providerConfig.path ?? "/usr/local/bin/claude"
                providerList.append(ProviderFactory.makeClaudeCode(claudePath: path))
                hasClaude = true

            case "shell":
                let shell = providerConfig.defaultShell ?? config.defaultShell
                providerList.append(ProviderFactory.makeShell(defaultShell: shell))
                hasShell = true

            default:
                // Custom CLI agent providers require type: "cli-agent" and a command template.
                if providerConfig.type == "cli-agent", let command = providerConfig.command {
                    providerList.append(ProviderFactory.makeCLIAgent(
                        name: name,
                        commandTemplate: command,
                        interactiveCommand: providerConfig.interactiveCommand
                    ))
                }
            }
        }

        // Ensure default providers are always available.
        if !hasShell {
            providerList.append(ProviderFactory.makeShell(defaultShell: config.defaultShell))
        }
        if !hasClaude {
            providerList.append(ProviderFactory.makeClaudeCode())
        }

        return ProviderRegistry(providers: providerList)
    }

    // MARK: - Project Initialization

    /// Initializes a new Orc project at the given path.
    ///
    /// Creates the `.orc/` directory structure, default `config.yml`, empty SQLite
    /// database (via `WorkflowStore`), and subdirectories for evaluators and workflows.
    ///
    /// This is a static method so the CLI can call it without first constructing a
    /// `WorkflowEngine` (which requires an existing `.orc/` directory).
    ///
    /// - Parameter path: The path where the `.orc` directory should be created.
    /// - Throws: `EngineError.projectAlreadyExists` if `.orc/` already exists,
    ///   or file-system / database errors.
    public static func initializeProject(at path: String) async throws {
        let fm = FileManager.default
        let orcDir = (path as NSString).appendingPathComponent(".orc")

        // Prevent re-initialization over an existing project.
        if fm.fileExists(atPath: orcDir) {
            throw EngineError.projectAlreadyExists(path: orcDir)
        }

        // Create .orc/ directory.
        try fm.createDirectory(atPath: orcDir, withIntermediateDirectories: true)

        // Create subdirectories for evaluators and workflows.
        let evaluatorsDir = (orcDir as NSString).appendingPathComponent("evaluators")
        let workflowsDir = (orcDir as NSString).appendingPathComponent("workflows")
        try fm.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: workflowsDir, withIntermediateDirectories: true)

        // Create default config.yml using nested YAML format matching the design spec.
        let configPath = (orcDir as NSString).appendingPathComponent("config.yml")
        let defaultConfig = """
        # Orc configuration
        # See https://github.com/orc-cli/orc for documentation.

        concurrency:
          max_parallel_nodes: \(ProcessInfo.processInfo.processorCount)

        storage:
          retention_days: 30
          retention_policy: completed_only

        providers:
          shell:
            default_shell: /bin/zsh
        """
        try defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Create orc.db (initializes schema via StoreFactory migrations).
        let dbPath = (orcDir as NSString).appendingPathComponent("orc.db")
        _ = try StoreFactory.makeStore(path: dbPath)
    }

    // MARK: - Core Operations

    /// Starts a new workflow run.
    ///
    /// Parses the workflow YAML, creates an execution plan, sets up a workspace,
    /// creates a run record, and dispatches all nodes.
    ///
    /// - Parameters:
    ///   - workflowFile: Path to the workflow YAML file.
    ///   - inputs: User-supplied input values.
    ///   - maxParallelNodes: Override for maximum parallel node execution. If nil,
    ///     uses the configured default.
    /// - Returns: The completed (or failed) `Run`.
    public func start(
        workflowFile: String,
        inputs: [String: String],
        maxParallelNodes: Int? = nil
    ) async throws -> Run {
        // Parse the workflow.
        let workflow = try parser.parse(file: workflowFile)

        // Build execution plan (topological sort).
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)

        // Determine max parallel nodes.
        let config = try configManager.loadConfig()
        let parallelLimit = maxParallelNodes ?? config.maxParallelNodes

        // Create the run record first so we get the real 8-char run ID.
        // Use a placeholder workspace path; we'll update it after creating the workspace.
        let pendingRun = Run(
            id: "",
            workflowName: workflow.name,
            workflowFile: workflowFile,
            status: .running,
            workspacePath: "",
            inputs: inputs,
            cleanupPolicy: workflow.cleanupPolicy
        )
        var run = try await store.createRun(pendingRun)

        // Now create the workspace using the actual run ID so the directory
        // name matches the run ID (not a random UUID).
        let workspacePath = try workspaceManager.createWorkspace(runID: run.id)

        // Update the run record with the real workspace path.
        try await store.updateRunWorkspacePath(id: run.id, workspacePath: workspacePath)
        run = Run(
            id: run.id,
            workflowName: run.workflowName,
            workflowFile: run.workflowFile,
            status: run.status,
            workspacePath: workspacePath,
            inputs: run.inputs,
            output: run.output,
            cleanupPolicy: run.cleanupPolicy,
            createdAt: run.createdAt,
            updatedAt: run.updatedAt
        )

        // Build internal handlers.
        let evaluatorRunner = EvaluatorRunner(
            providers: providers,
            store: store,
            templateResolver: templateResolver,
            processRunner: ProviderFactory.makeProcessRunner(),
            basePath: workspaceManager.basePath
        )

        let tmuxSession = ProviderFactory.makeTmuxSession()

        let interactiveHandler = InteractiveHandler(
            store: store,
            providers: providers,
            tmux: tmuxSession,
            templateResolver: templateResolver
        )

        let loopHandler = LoopHandler(
            providers: providers,
            store: store,
            evaluatorRunner: evaluatorRunner,
            templateResolver: templateResolver,
            tmux: tmuxSession
        )

        // Dispatch nodes.
        let dispatcher = NodeDispatcher(
            plan: plan,
            providers: providers,
            store: store,
            parser: parser,
            templateResolver: templateResolver,
            expressionEvaluator: expressionEvaluator,
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: parallelLimit
        )

        let startTime = Date()

        // Store the dispatch task so cancel() can cancel it, propagating
        // cooperative cancellation down to ProcessRunner's SIGTERM handler.
        let dispatchTask = Task<Run, Error> {
            try await dispatcher.execute(run: run, inputs: inputs)
        }
        runningTasks[run.id] = dispatchTask

        let completedRun: Run
        do {
            completedRun = try await dispatchTask.value
        } catch {
            runningTasks.removeValue(forKey: run.id)
            throw error
        }
        runningTasks.removeValue(forKey: run.id)

        let duration = Date().timeIntervalSince(startTime)

        // Record stats.
        try await store.recordStats(
            run: completedRun,
            nodeCount: workflow.nodes.count,
            duration: duration
        )

        // Cleanup workspace if needed.
        try? workspaceManager.cleanupWorkspace(
            runID: run.id,
            policy: workflow.cleanupPolicy,
            runStatus: completedRun.status
        )

        return completedRun
    }

    /// Resumes a previously failed, cancelled, or awaiting-input run.
    ///
    /// Re-parses the workflow (which may have been modified), validates that all
    /// previously completed nodes still exist, and re-dispatches from the failure point.
    ///
    /// - Parameter runID: The ID of the run to resume.
    /// - Returns: The completed (or failed) `Run`.
    public func resume(runID: String) async throws -> Run {
        let resumeHandler = ResumeHandler(store: store, parser: parser)
        let (run, workflow, completedOutputs) = try await resumeHandler.prepareResume(runID: runID)

        // Build execution plan from the (possibly updated) workflow.
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)

        let config = try configManager.loadConfig()

        // Mark run as running.
        try await store.updateRunStatus(id: run.id, status: .running)

        // Build handlers.
        let evaluatorRunner = EvaluatorRunner(
            providers: providers,
            store: store,
            templateResolver: templateResolver,
            processRunner: ProviderFactory.makeProcessRunner(),
            basePath: workspaceManager.basePath
        )

        let tmuxSession = ProviderFactory.makeTmuxSession()

        let interactiveHandler = InteractiveHandler(
            store: store,
            providers: providers,
            tmux: tmuxSession,
            templateResolver: templateResolver
        )

        let loopHandler = LoopHandler(
            providers: providers,
            store: store,
            evaluatorRunner: evaluatorRunner,
            templateResolver: templateResolver,
            tmux: tmuxSession
        )

        let dispatcher = NodeDispatcher(
            plan: plan,
            providers: providers,
            store: store,
            parser: parser,
            templateResolver: templateResolver,
            expressionEvaluator: expressionEvaluator,
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: config.maxParallelNodes
        )

        let startTime = Date()

        // Store the dispatch task so cancel() can cancel it, propagating
        // cooperative cancellation down to ProcessRunner's SIGTERM handler.
        let dispatchTask = Task<Run, Error> {
            try await dispatcher.execute(
                run: run,
                inputs: run.inputs ?? [:],
                completedOutputs: completedOutputs
            )
        }
        runningTasks[run.id] = dispatchTask

        let completedRun: Run
        do {
            completedRun = try await dispatchTask.value
        } catch {
            runningTasks.removeValue(forKey: run.id)
            throw error
        }
        runningTasks.removeValue(forKey: run.id)

        let duration = Date().timeIntervalSince(startTime)

        try await store.recordStats(
            run: completedRun,
            nodeCount: workflow.nodes.count,
            duration: duration
        )

        return completedRun
    }

    /// Cancels a running workflow.
    ///
    /// Marks the run and all pending/running node executions as cancelled.
    /// Actual process termination is handled via Task cancellation.
    ///
    /// - Parameter runID: The ID of the run to cancel.
    public func cancel(runID: String) async throws {
        // Cancel the in-flight Swift Task first so cooperative cancellation
        // propagates to ProcessRunner, which sends SIGTERM to child processes.
        if let task = runningTasks.removeValue(forKey: runID) {
            task.cancel()
        }

        let handler = CancellationHandler(store: store, tmux: ProviderFactory.makeTmuxSession())
        try await handler.cancel(runID: runID)
    }

    /// Provides a response to an interactive node that is awaiting input.
    ///
    /// - Parameters:
    ///   - runID: The run ID containing the awaiting node.
    ///   - nodeID: The node ID to respond to.
    ///   - response: The user's response text.
    public func respond(runID: String, nodeID: String, response: String) async throws {
        let handler = InteractiveHandler(
            store: store, providers: providers,
            tmux: ProviderFactory.makeTmuxSession(), templateResolver: templateResolver
        )
        try await handler.respond(store: store, runID: runID, nodeID: nodeID, response: response)

        // Re-dispatch the workflow so downstream nodes that depend on
        // this interactive response can proceed (design spec §7.4).
        // The run is still in .awaitingInput status, which resume()
        // accepts as resumable via ResumeHandler.prepareResume().
        _ = try await resume(runID: runID)
    }

    // MARK: - Query API

    /// Lists all runs, optionally filtered by status.
    public func listRuns(status: RunStatus? = nil) async throws -> [Run] {
        try await store.listRuns(status: status)
    }

    /// Gets the current status of a run.
    public func getStatus(runID: String) async throws -> Run? {
        try await store.getRun(id: runID)
    }

    /// Gets node execution records for a run, optionally filtered by node ID.
    public func getNodeExecutions(
        runID: String,
        nodeID: String? = nil
    ) async throws -> [NodeExecution] {
        try await store.getNodeExecutions(runID: runID, nodeID: nodeID)
    }

    /// Gets log entries for node executions, with optional filtering.
    public func getLogs(
        runID: String,
        nodeID: String? = nil,
        attempt: Int? = nil,
        iteration: Int? = nil
    ) async throws -> [LogEntry] {
        let executions = try await store.getNodeExecutions(runID: runID, nodeID: nodeID)
        var allLogs: [LogEntry] = []

        for exec in executions {
            // Apply optional filters.
            if let attempt = attempt, exec.attempt != attempt { continue }
            if let iteration = iteration, exec.iteration != iteration { continue }

            let logs = try await store.getLogEntries(nodeExecutionID: exec.id)
            allLogs.append(contentsOf: logs)
        }

        return allLogs
    }

    /// Gets aggregated run statistics.
    public func getStats() async throws -> [RunStats] {
        try await store.getStats()
    }

    // MARK: - Validation

    /// Validates a workflow YAML file without executing it.
    ///
    /// Parses the file and runs structural validation, returning any errors
    /// and warnings found.
    ///
    /// - Parameter workflowFile: Path to the workflow YAML file.
    /// - Returns: A `ValidationResult` with errors and warnings.
    public func validate(workflowFile: String) throws -> ValidationResult {
        let workflow = try parser.parse(file: workflowFile)
        return parser.validate(workflow: workflow)
    }

    // MARK: - Configuration

    /// Gets a configuration value by dot-notation key.
    ///
    /// - Parameter key: The dot-notation key (e.g., "concurrency.max_parallel_nodes").
    /// - Returns: The string value, or nil if not set.
    public func getConfigValue(key: String) throws -> String? {
        try configManager.getValue(key: key)
    }

    /// Sets a configuration value by dot-notation key.
    ///
    /// - Parameters:
    ///   - key: The dot-notation key.
    ///   - value: The value to set.
    public func setConfigValue(key: String, value: String) throws {
        try configManager.setValue(key: key, value: value)
    }

    /// Removes a configuration value by dot-notation key.
    ///
    /// - Parameter key: The dot-notation key to remove.
    public func unsetConfigValue(key: String) throws {
        try configManager.unsetValue(key: key)
    }

    /// Loads the full configuration, merging with defaults.
    ///
    /// - Returns: A fully populated `OrcConfig`.
    public func loadConfig() throws -> OrcConfig {
        try configManager.loadConfig()
    }

    // MARK: - Workspace Management

    /// Removes the workspace directory for a specific run.
    ///
    /// - Parameter runID: The run ID whose workspace to remove.
    public func cleanupWorkspace(runID: String) async throws {
        guard let run = try await store.getRun(id: runID) else {
            throw EngineError.runNotFound(id: runID)
        }
        try workspaceManager.cleanupWorkspace(
            runID: runID,
            policy: .always,
            runStatus: run.status
        )
    }

    /// Purges runs older than the given date and/or matching a status filter.
    ///
    /// Also removes workspace directories for purged runs.
    ///
    /// - Parameters:
    ///   - olderThan: Delete runs older than this date. If nil, no date filter.
    ///   - status: Only delete runs with this status. If nil, delete all matching.
    public func purge(olderThan: Date?, status: RunStatus?) async throws {
        // Get the runs that will be purged so we can remove their workspaces.
        let runs = try await store.listRuns(status: status)
        var purgedCount = 0

        for run in runs {
            let shouldPurge: Bool
            if let cutoff = olderThan {
                shouldPurge = run.updatedAt < cutoff
            } else {
                shouldPurge = true
            }

            if shouldPurge {
                // Remove workspace if it exists.
                try? workspaceManager.cleanupWorkspace(
                    runID: run.id,
                    policy: .always,
                    runStatus: run.status
                )
                purgedCount += 1
            }
        }

        // Delete from DB.
        if let cutoff = olderThan {
            try await store.deleteRuns(olderThan: cutoff, status: status)
        } else {
            // Delete all matching runs by using a far-future date.
            try await store.deleteRuns(olderThan: Date.distantFuture, status: status)
        }
    }

    /// Returns the path to the `.orc` directory this engine was initialized with.
    public nonisolated var basePath: String {
        workspaceManager.basePath
    }
}
