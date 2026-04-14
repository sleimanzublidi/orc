import Foundation
import Logging
import Models
import Providers
import Template

/// Walks the DAG using a TaskGroup, dispatching ready nodes concurrently.
///
/// Maintains mutable execution context (inputs, outputs, node statuses) and
/// coordinates parallel execution with a bounded concurrency limit.
struct NodeDispatcher: Sendable {
    let plan: ExecutionPlan
    let providers: ProviderRegistry
    let store: any WorkflowStoring
    let parser: any WorkflowParsing
    let templateResolver: any TemplateResolving
    let expressionEvaluator: any ExpressionEvaluating
    let evaluatorRunner: EvaluatorRunner
    let interactiveHandler: InteractiveHandler
    let loopHandler: LoopHandler
    let maxParallelNodes: Int
    let repoRoot: String
    let environment: [String: String]
    let onEvent: @Sendable (WorkflowEvent) -> Void

    private let logger = Logger(label: "orc.engine.dispatcher")

    init(
        plan: ExecutionPlan,
        providers: ProviderRegistry,
        store: any WorkflowStoring,
        parser: any WorkflowParsing,
        templateResolver: any TemplateResolving,
        expressionEvaluator: any ExpressionEvaluating,
        evaluatorRunner: EvaluatorRunner,
        interactiveHandler: InteractiveHandler,
        loopHandler: LoopHandler,
        maxParallelNodes: Int,
        repoRoot: String,
        environment: [String: String],
        onEvent: @escaping @Sendable (WorkflowEvent) -> Void = { _ in }
    ) {
        self.plan = plan
        self.providers = providers
        self.store = store
        self.parser = parser
        self.templateResolver = templateResolver
        self.expressionEvaluator = expressionEvaluator
        self.evaluatorRunner = evaluatorRunner
        self.interactiveHandler = interactiveHandler
        self.loopHandler = loopHandler
        self.maxParallelNodes = maxParallelNodes
        self.repoRoot = repoRoot
        self.environment = environment
        self.onEvent = onEvent
    }

    /// Executes the workflow DAG, dispatching nodes in dependency order.
    ///
    /// - Parameters:
    ///   - run: The workflow run to execute.
    ///   - inputs: The user-supplied input values.
    ///   - completedOutputs: Previously completed node outputs (for resume).
    /// - Returns: The run with updated status (completed or failed).
    func execute(
        run: Run,
        inputs: [String: String],
        completedOutputs: [String: String] = [:]
    ) async throws -> Run {
        // Initialize mutable execution state.
        var nodeOutputs: [String: String] = completedOutputs
        var nodeStatuses: [String: NodeStatus] = [:]
        // Stores the runtime-resolved onFailure strategy for each node.
        // This is populated after each node executes so that dependency
        // checking and skip cascading use the resolved value rather than
        // the raw Resolvable (which may be a .template expression).
        var resolvedOnFailure: [String: FailureStrategy] = [:]

        // Merge workflow input defaults into the provided inputs.
        // This ensures that inputs with default values are available even when
        // the caller does not provide them, and validates that all required
        // inputs without defaults are present.
        var mutableInputs = inputs
        for workflowInput in plan.workflow.input {
            if mutableInputs[workflowInput.name] == nil {
                if let defaultTemplate = workflowInput.defaultValue {
                    let defaultContext = TaskContext(
                        inputs: mutableInputs,
                        repoRoot: repoRoot,
                        workspacePath: run.workspacePath,
                        environment: environment
                    )
                    let resolved = try templateResolver.resolve(
                        template: defaultTemplate, context: defaultContext
                    )
                    mutableInputs[workflowInput.name] = resolved
                } else if workflowInput.required {
                    throw EngineError.missingRequiredInput(
                        name: workflowInput.name,
                        workflow: plan.workflow.name
                    )
                }
            }
        }
        // Freeze after all defaults are resolved — mergedInputs is immutable
        // from here, which satisfies Sendable requirements for task group closures.
        let mergedInputs = mutableInputs

        // Mark previously completed nodes.
        for nodeID in completedOutputs.keys {
            nodeStatuses[nodeID] = .completed
        }

        // Track which nodes are ready to run.
        var pendingNodes = Set(plan.topologicalOrder.filter { nodeStatuses[$0] == nil })
        var runFailed = false
        // Track nodes that entered awaitingInput — these don't unblock dependents
        // but they also don't stop the run; they pause it.
        var awaitingNodes = Set<String>()

        // Process nodes in topological order.
        // Nodes with satisfied dependencies are dispatched concurrently up to maxParallelNodes.
        while !pendingNodes.isEmpty {
            try Task.checkCancellation()

            // Find all nodes whose dependencies are satisfied.
            let readyNodes = pendingNodes.filter { nodeID in
                isNodeReady(
                    nodeID: nodeID,
                    nodeStatuses: nodeStatuses,
                    resolvedOnFailure: resolvedOnFailure
                )
            }

            if readyNodes.isEmpty {
                // All remaining nodes have unsatisfied dependencies.
                // This can happen if upstream nodes failed with .stop strategy,
                // or if some upstream nodes are awaitingInput (paused).
                break
            }

            // Dispatch ready nodes concurrently, bounded by maxParallelNodes.
            //
            // TODO(M11): Known limitation — batch-sequential dispatch. The current
            // approach dispatches a batch, waits for ALL nodes in the batch to
            // complete, then dispatches the next batch. This is correct but
            // suboptimal for latency: if one node in a batch finishes early and
            // unblocks new nodes, those new nodes must wait until the entire
            // batch completes before being dispatched. A streaming approach that
            // processes results one-at-a-time from the TaskGroup and immediately
            // checks for newly unblocked nodes would improve throughput.
            let batchSize = min(readyNodes.count, maxParallelNodes)
            let batch = Array(readyNodes.sorted().prefix(batchSize))

            let nodeList = batch.joined(separator: ", ")
            logger.debug("batch: [\(nodeList)]")

            // Snapshot mutable state before entering the task group so the
            // closure captures immutable copies (required by strict concurrency).
            let snapshotOutputs = nodeOutputs
            let snapshotStatuses = nodeStatuses

            // Execute the batch using a TaskGroup.
            // Each result includes the resolved onFailure strategy so the
            // post-batch failure handling uses the runtime-resolved value
            // instead of the raw Resolvable (which may be a template).
            let results: [(String, NodeStatus, String?, (any Error)?, FailureStrategy)] =
                try await withThrowingTaskGroup(
                    of: (String, NodeStatus, String?, (any Error)?, FailureStrategy).self
                ) { group in
                    for nodeID in batch {
                        group.addTask {
                            try await self.executeNode(
                                nodeID: nodeID,
                                run: run,
                                inputs: mergedInputs,
                                nodeOutputs: snapshotOutputs,
                                nodeStatuses: snapshotStatuses
                            )
                        }
                    }

                    var collected: [(String, NodeStatus, String?, (any Error)?, FailureStrategy)] = []
                    for try await result in group {
                        collected.append(result)
                    }
                    return collected
                }

            // Apply results to our state.
            for (nodeID, status, output, _, resolvedStrategy) in results {
                nodeStatuses[nodeID] = status
                resolvedOnFailure[nodeID] = resolvedStrategy
                pendingNodes.remove(nodeID)

                if status == .completed {
                    logger.info("[\(nodeID)] completed")
                } else if status == .failed {
                    let detail = results.first(where: { $0.0 == nodeID })?.3?.localizedDescription ?? "unknown"
                    logger.info("[\(nodeID)] failed: \(detail)")
                }

                if let output = output {
                    nodeOutputs[nodeID] = output
                    // Also store under the node's output alias if configured.
                    if let node = plan.nodesByID[nodeID], let alias = node.output {
                        nodeOutputs[alias] = output
                    }
                }

                if status == .awaitingInput {
                    // The node is paused waiting for user input. Track it so we
                    // can set the run to awaitingInput later. It does NOT unblock
                    // dependents, but it also doesn't fail the run — other
                    // independent branches can still proceed.
                    awaitingNodes.insert(nodeID)
                } else if status == .failed {
                    let strategy = resolvedOnFailure[nodeID] ?? .stop

                    switch strategy {
                    case .stop:
                        runFailed = true
                        // Mark all remaining pending nodes as cancelled.
                        for remaining in pendingNodes {
                            nodeStatuses[remaining] = .cancelled
                            let execID = UUID().uuidString
                            let exec = NodeExecution(
                                id: execID,
                                runID: run.id,
                                nodeID: remaining,
                                status: .cancelled,
                                startedAt: Date(),
                                completedAt: Date()
                            )
                            do {
                                _ = try await store.createNodeExecution(exec)
                            } catch {
                                logger.warning("[\(remaining)] Failed to persist cancelled execution: \(error)")
                            }
                        }
                        pendingNodes.removeAll()

                    case .skip:
                        // Skip dependents: mark all downstream nodes as skipped.
                        skipDependents(
                            of: nodeID,
                            run: run,
                            pendingNodes: &pendingNodes,
                            nodeStatuses: &nodeStatuses,
                            resolvedOnFailure: resolvedOnFailure
                        )

                    case .continue:
                        // Continue: downstream nodes can still run.
                        break
                    }
                } else if status == .skipped {
                    // Propagate skip to dependents if all their deps are skipped.
                    cascadeSkips(
                        from: nodeID,
                        run: run,
                        pendingNodes: &pendingNodes,
                        nodeStatuses: &nodeStatuses
                    )
                }
            }

            if runFailed {
                break
            }
        }

        // Determine final run status.
        // If any nodes are awaiting input, the run is paused (not completed/failed).
        // This ensures `orc respond` can provide a response and re-dispatch.
        let finalStatus: RunStatus
        if runFailed {
            finalStatus = .failed
        } else if !awaitingNodes.isEmpty {
            finalStatus = .awaitingInput
        } else {
            finalStatus = .completed
        }

        try await store.updateRunStatus(id: run.id, status: finalStatus)

        // If the workflow has an output mapping, resolve it.
        if finalStatus == .completed, let outputMap = plan.workflow.output {
            let context = TaskContext(
                inputs: mergedInputs,
                outputs: nodeOutputs,
                nodeStatuses: nodeStatuses,
                repoRoot: repoRoot,
                workspacePath: run.workspacePath,
                environment: environment
            )
            var finalOutputParts: [String] = []
            for (key, template) in outputMap.sorted(by: { $0.key < $1.key }) {
                let resolved = try? templateResolver.resolve(template: template, context: context)
                finalOutputParts.append("\(key): \(resolved ?? template)")
            }
            let finalOutput = finalOutputParts.joined(separator: "\n")
            try await store.updateRunOutput(id: run.id, output: finalOutput)
        }

        // Return the updated run.
        let updatedRun = try await store.getRun(id: run.id)
        return updatedRun ?? run
    }

    // MARK: - Node Execution

    /// Executes a single node and returns its result.
    ///
    /// - Returns: A tuple of (nodeID, status, output, error, resolvedOnFailure).
    ///   The resolved `FailureStrategy` is included so the caller can use the
    ///   runtime-resolved value (which handles template expressions) instead of
    ///   the raw `Resolvable` on the node definition.
    private func executeNode(
        nodeID: String,
        run: Run,
        inputs: [String: String],
        nodeOutputs: [String: String],
        nodeStatuses: [String: NodeStatus]
    ) async throws -> (String, NodeStatus, String?, (any Error)?, FailureStrategy) {
        guard let node = plan.nodesByID[nodeID] else {
            return (nodeID, .failed, nil, EngineError.dependencyFailed(nodeID: nodeID, upstream: "node not found"), .stop)
        }

        logger.info("[\(nodeID)] running...")

        let context = TaskContext(
            inputs: inputs,
            outputs: nodeOutputs,
            nodeStatuses: nodeStatuses,
            repoRoot: repoRoot,
            workspacePath: run.workspacePath,
            environment: environment
        )

        // Evaluate when: guard expression.
        if let whenExpr = node.when {
            do {
                let shouldRun = try expressionEvaluator.evaluate(expression: whenExpr, context: context)
                if !shouldRun {
                    // Create a skipped execution record.
                    let execID = UUID().uuidString
                    let exec = NodeExecution(
                        id: execID,
                        runID: run.id,
                        nodeID: nodeID,
                        status: .skipped,
                        startedAt: Date(),
                        completedAt: Date()
                    )
                    _ = try await store.createNodeExecution(exec)
                    logger.info("[\(nodeID)] skipped (when: condition false)")
                    onEvent(.nodeSkipped(nodeID: nodeID, runID: run.id))
                    // Use literalValue fallback since config hasn't been resolved yet.
                    return (nodeID, .skipped, nil, nil, node.onFailure.literalValue ?? .stop)
                }
            } catch {
                // when: expression evaluation failure is treated as a node failure.
                let execID = UUID().uuidString
                let exec = NodeExecution(
                    id: execID,
                    runID: run.id,
                    nodeID: nodeID,
                    status: .failed,
                    error: "when: expression failed: \(error)",
                    startedAt: Date(),
                    completedAt: Date()
                )
                _ = try await store.createNodeExecution(exec)
                // Use literalValue fallback since config hasn't been resolved yet.
                return (nodeID, .failed, nil, error, node.onFailure.literalValue ?? .stop)
            }
        }

        // Resolve all Resolvable config fields into typed values before dispatch.
        let config: ResolvedNodeConfig
        do {
            config = try resolveNodeConfig(node, context: context)
        } catch {
            let execID = UUID().uuidString
            let exec = NodeExecution(
                id: execID,
                runID: run.id,
                nodeID: nodeID,
                status: .failed,
                error: "Config resolution failed: \(error)",
                startedAt: Date(),
                completedAt: Date()
            )
            do {
                _ = try await store.createNodeExecution(exec)
            } catch {
                logger.warning("[\(nodeID)] Failed to persist config resolution failure: \(error)")
            }
            // Config resolution failed — the onFailure template itself could
            // not be resolved. Fall back to the literal value or .stop.
            return (nodeID, .failed, nil, error, node.onFailure.literalValue ?? .stop)
        }

        // All sub-methods return 4-tuples; we append the resolved onFailure
        // strategy so the caller can use it for failure handling decisions.

        // Handle interactive nodes.
        if let interactive = node.interactive {
            let result = await executeInteractiveNode(
                node: node, interactive: interactive, run: run, context: context,
                config: config
            )
            return (result.0, result.1, result.2, result.3, config.onFailure)
        }

        // Handle loop+workflow nodes: each iteration dispatches the child
        // workflow's DAG instead of calling a provider.
        if node.loop != nil && node.workflow != nil {
            let result = await executeLoopWorkflowNode(
                node: node, run: run, context: context, config: config
            )
            return (result.0, result.1, result.2, result.3, config.onFailure)
        }

        // Handle loop nodes (agent-based).
        if node.loop != nil {
            let result = await executeLoopNode(
                node: node, run: run, context: context, config: config
            )
            return (result.0, result.1, result.2, result.3, config.onFailure)
        }

        // Handle nested workflow nodes (single execution).
        if node.workflow != nil {
            let result = await executeNestedWorkflow(
                node: node, run: run, context: context, config: config
            )
            return (result.0, result.1, result.2, result.3, config.onFailure)
        }

        // Standard single-execution node.
        let result = await executeSingleNode(node: node, run: run, context: context, config: config)
        return (result.0, result.1, result.2, result.3, config.onFailure)
    }

    /// Executes a standard (non-loop, non-interactive) node.
    private func executeSingleNode(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        config: ResolvedNodeConfig
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        let execID = UUID().uuidString
        let agentName = config.agent ?? "shell"

        // Resolve the prompt/command template.
        let resolvedPrompt: String
        do {
            if let command = node.command {
                resolvedPrompt = try templateResolver.resolve(template: command, context: context)
            } else if let prompt = node.prompt {
                resolvedPrompt = try templateResolver.resolve(template: prompt, context: context)
            } else if let promptFile = node.promptFile {
                let resolvedPath = try templateResolver.resolve(template: promptFile, context: context)
                let fileContents = try String(contentsOfFile: resolvedPath, encoding: .utf8)
                resolvedPrompt = try templateResolver.resolve(template: fileContents, context: context)
            } else {
                resolvedPrompt = ""
            }
        } catch {
            let exec = NodeExecution(
                id: execID,
                runID: run.id,
                nodeID: node.id,
                status: .failed,
                agent: agentName,
                error: "Template resolution failed: \(error)",
                startedAt: Date(),
                completedAt: Date()
            )
            do {
                _ = try await store.createNodeExecution(exec)
            } catch {
                logger.warning("[\(node.id)] Failed to persist failed execution: \(error)")
            }
            return (node.id, .failed, nil, error)
        }

        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            agent: agentName,
            prompt: resolvedPrompt,
            startedAt: Date()
        )
        do {
            _ = try await store.createNodeExecution(exec)
        } catch {
            logger.warning("[\(node.id)] Failed to persist running execution: \(error)")
        }

        // Emit nodeStarted before entering the retry loop.
        onEvent(.nodeStarted(nodeID: node.id, runID: run.id, agent: agentName))

        // Execute with retry support using resolved config values.
        let maxAttempts = config.retry?.maxAttempts ?? 1
        var lastError: (any Error)?

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                logger.debug("[\(node.id)] retry \(attempt)/\(maxAttempts)...")
            }
            do {
                let provider = try providers.provider(named: agentName)

                let stream = provider.executeStreaming(
                    prompt: resolvedPrompt, context: context,
                    timeout: config.timeoutSeconds,
                    parameters: config.parameters
                )

                var finalOutput: TaskOutput?
                for try await event in stream {
                    switch event {
                    case .output(let chunk, let streamType):
                        onEvent(.nodeOutput(nodeID: node.id, runID: run.id, chunk: chunk, stream: streamType))
                    case .completed(let output):
                        finalOutput = output
                    }
                }

                guard let output = finalOutput else {
                    throw EngineError.nodeExecutionFailed(nodeID: node.id, detail: "No output received from provider")
                }

                try await store.updateNodeExecution(
                    id: execID,
                    status: .completed,
                    output: output.output,
                    error: nil
                )

                onEvent(.nodeCompleted(nodeID: node.id, runID: run.id, output: output.output))
                return (node.id, .completed, output.output, nil)
            } catch {
                lastError = error
                logger.debug("[\(node.id)] attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    if let delay = config.retry?.delaySeconds, delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    }
                }
            }
        }

        // All attempts exhausted.
        onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: lastError?.localizedDescription ?? "unknown"))

        do {
            try await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: lastError?.localizedDescription
            )
        } catch {
            logger.warning("[\(node.id)] Failed to persist failure status: \(error)")
        }

        return (node.id, .failed, nil, lastError)
    }

    /// Executes an interactive node (session or prompt mode) with retry support.
    ///
    /// H8: Session-mode interactive nodes support retry — if a session fails, it
    /// can be retried up to `node.retry.maxAttempts` times. Prompt-mode nodes do
    /// not retry because they enter the awaiting_input state, which is not a failure.
    private func executeInteractiveNode(
        node: Models.Node,
        interactive: InteractiveMode,
        run: Run,
        context: TaskContext,
        config: ResolvedNodeConfig
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        let execID = UUID().uuidString

        let message: String?
        if case .prompt(let msg) = interactive {
            message = msg
        } else {
            message = nil
        }

        // Compute the tmux session name up front so it can be persisted in the
        // NodeExecution record. CancellationHandler reads tmuxSession to destroy
        // interactive sessions on cancel — without this, it would always be nil.
        let sessionName: String? = interactive == .session
            ? "orc-\(run.id)-\(node.id)"
            : nil

        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            agent: config.agent,
            message: message,
            tmuxSession: sessionName,
            startedAt: Date()
        )
        do {
            _ = try await store.createNodeExecution(exec)
        } catch {
            logger.warning("[\(node.id)] Failed to persist interactive execution: \(error)")
        }

        switch interactive {
        case .session:
            // sessionName is guaranteed non-nil in the .session branch.
            let resolvedSessionName = sessionName!
            let maxAttempts = config.retry?.maxAttempts ?? 1
            var lastError: (any Error)?

            for attempt in 1...maxAttempts {
                do {
                    let output = try await interactiveHandler.handleSession(
                        node: node, run: run, context: context,
                        sessionName: resolvedSessionName, nodeExecutionID: execID,
                        agentName: config.agent ?? "shell"
                    )
                    try await store.updateNodeExecution(
                        id: execID,
                        status: .completed,
                        output: output.output,
                        error: nil
                    )
                    return (node.id, .completed, output.output, nil)
                } catch {
                    lastError = error
                    if attempt < maxAttempts {
                        if let delay = config.retry?.delaySeconds, delay > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        }
                    }
                }
            }

            // All retry attempts exhausted.
            do {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: lastError?.localizedDescription
                )
            } catch {
                logger.warning("[\(node.id)] Failed to persist session failure status: \(error)")
            }
            return (node.id, .failed, nil, lastError)

        case .prompt:
            do {
                try await interactiveHandler.handlePrompt(
                    node: node, run: run, nodeExecutionID: execID
                )
                // The node is now awaiting_input. The dispatcher returns and the
                // run will be set to awaiting_input status.
                return (node.id, .awaitingInput, nil, nil)
            } catch {
                do {
                    try await store.updateNodeExecution(
                        id: execID,
                        status: .failed,
                        output: nil,
                        error: error.localizedDescription
                    )
                } catch let storeError {
                    logger.warning("[\(node.id)] Failed to persist prompt failure status: \(storeError)")
                }
                return (node.id, .failed, nil, error)
            }
        }
    }

    /// Executes a loop node by delegating to the LoopHandler, with retry support.
    ///
    /// H8: The entire loop is retried if it fails (e.g., provider error or
    /// maxIterationsReached). Each retry restarts the loop from iteration 1.
    private func executeLoopNode(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        config: ResolvedNodeConfig
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        let agentName = config.agent ?? "shell"
        let maxAttempts = config.retry?.maxAttempts ?? 1
        var lastError: (any Error)?

        guard let loopConfig = config.loop else {
            let error = EngineError.invalidConfigValue(
                node: node.id, field: "loop", value: "nil", expected: "loop configuration"
            )
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: error.localizedDescription))
            return (node.id, .failed, nil, error)
        }

        onEvent(.nodeStarted(nodeID: node.id, runID: run.id, agent: agentName))

        for attempt in 1...maxAttempts {
            do {
                let output = try await loopHandler.executeLoop(
                    node: node, run: run, context: context,
                    loopConfig: loopConfig,
                    agentName: agentName,
                    timeoutSeconds: config.timeoutSeconds,
                    parameters: config.parameters,
                    retryConfig: config.retry
                )
                onEvent(.nodeCompleted(nodeID: node.id, runID: run.id, output: output.output))
                return (node.id, .completed, output.output, nil)
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    if let delay = config.retry?.delaySeconds, delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    }
                }
            }
        }

        onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: lastError?.localizedDescription ?? "unknown"))
        return (node.id, .failed, nil, lastError)
    }

    // MARK: - Loop + Workflow Execution

    /// Executes a node that combines `loop:` and `workflow:`, running the child
    /// workflow's full DAG on each iteration.
    ///
    /// The child workflow YAML is parsed and planned once. Each iteration resolves
    /// the node's `inputs:` mapping against the current context (which includes
    /// `{{last_output}}` from the previous iteration), creates a child run, and
    /// dispatches the child DAG via a child `NodeDispatcher`. The evaluator is run
    /// after each iteration to decide whether to stop.
    ///
    /// Outer retry logic wraps the entire loop (same behavior as `executeLoopNode`).
    private func executeLoopWorkflowNode(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        config: ResolvedNodeConfig
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        guard let loopConfig = config.loop else {
            let error = EngineError.invalidConfigValue(
                node: node.id, field: "loop", value: "nil", expected: "loop configuration"
            )
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: error.localizedDescription))
            return (node.id, .failed, nil, error)
        }
        guard let workflowFile = node.workflow else {
            let error = EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: "nil", detail: "No workflow file specified"
            )
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: error.localizedDescription))
            return (node.id, .failed, nil, error)
        }

        onEvent(.nodeStarted(nodeID: node.id, runID: run.id, agent: "nested-workflow"))

        // Parse and plan the child workflow once — the definition doesn't change
        // between iterations.
        let childWorkflow: Workflow
        do {
            childWorkflow = try parser.parse(file: workflowFile)
        } catch {
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: error.localizedDescription))
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Parse failed: \(error)"
            ))
        }

        let childPlan: ExecutionPlan
        do {
            let planner = ExecutionPlanner()
            childPlan = try planner.plan(workflow: childWorkflow)
        } catch {
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: error.localizedDescription))
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Planning failed: \(error)"
            ))
        }

        // Determine workspace path once.
        let childWorkspacePath: String
        let workspaceMode = config.workspaceMode ?? .shared
        switch workspaceMode {
        case .shared:
            childWorkspacePath = run.workspacePath
        case .isolated:
            let nodeDir = (run.workspacePath as NSString)
                .appendingPathComponent("nested")
                .appendingPathComponent(node.id)
            do {
                try FileManager.default.createDirectory(
                    atPath: nodeDir, withIntermediateDirectories: true
                )
            } catch {
                onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: error.localizedDescription))
                return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                    nodeID: node.id, workflowFile: workflowFile,
                    detail: "Workspace creation failed: \(error)"
                ))
            }
            childWorkspacePath = nodeDir
        }

        // Outer retry wrapping (same as executeLoopNode).
        let maxAttempts = config.retry?.maxAttempts ?? 1
        var lastError: (any Error)?

        for attempt in 1...maxAttempts {
            do {
                let output = try await runWorkflowLoop(
                    node: node, run: run, context: context,
                    loopConfig: loopConfig,
                    workflowFile: workflowFile,
                    childWorkflow: childWorkflow,
                    childPlan: childPlan,
                    childWorkspacePath: childWorkspacePath
                )
                onEvent(.nodeCompleted(nodeID: node.id, runID: run.id, output: output))
                return (node.id, .completed, output, nil)
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    if let delay = config.retry?.delaySeconds, delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    }
                }
            }
        }

        onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: lastError?.localizedDescription ?? "unknown"))
        return (node.id, .failed, nil, lastError)
    }

    /// Runs the iteration loop for a loop+workflow node, returning the final output.
    ///
    /// Each iteration resolves inputs, creates a child run, dispatches the child
    /// DAG, extracts output, and runs the evaluator.
    private func runWorkflowLoop(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        loopConfig: ResolvedLoopConfig,
        workflowFile: String,
        childWorkflow: Workflow,
        childPlan: ExecutionPlan,
        childWorkspacePath: String
    ) async throws -> String {
        var lastOutput = ""
        var previousOutput: String? = nil
        let maxIterations = loopConfig.maxIterations

        // Seed last_output so {{last_output}} resolves on the first iteration
        // (matches LoopHandler behavior for agent-based loops).
        var initialOutputs = context.outputs
        if initialOutputs["last_output"] == nil {
            initialOutputs["last_output"] = ""
        }
        var currentContext = TaskContext(
            inputs: context.inputs,
            outputs: initialOutputs,
            nodeStatuses: context.nodeStatuses,
            repoRoot: context.repoRoot,
            workspacePath: context.workspacePath,
            environment: context.environment
        )

        for iteration in 1...maxIterations {
            try Task.checkCancellation()

            logger.info("[\(node.id)] iteration \(iteration)/\(maxIterations)...")

            // Resolve inputs against current context (includes {{last_output}}).
            var childInputs: [String: String] = [:]
            if let inputMappings = node.inputs {
                for (key, template) in inputMappings {
                    childInputs[key] = try templateResolver.resolve(
                        template: template, context: currentContext
                    )
                }
            }

            // Validate required inputs.
            for childInput in childWorkflow.input {
                if childInput.required && childInput.defaultValue == nil
                    && childInputs[childInput.name] == nil
                {
                    throw EngineError.missingRequiredInput(
                        name: childInput.name, workflow: childWorkflow.name
                    )
                }
            }

            // Record iteration in the parent's execution log.
            let execID = UUID().uuidString
            let execution = NodeExecution(
                id: execID,
                runID: run.id,
                nodeID: node.id,
                status: .running,
                agent: "nested-workflow",
                attempt: 1,
                iteration: iteration,
                startedAt: Date()
            )
            _ = try await store.createNodeExecution(execution)

            // Create a child run for this iteration.
            let childRunTemplate = Run(
                id: "",
                workflowName: childWorkflow.name,
                workflowFile: workflowFile,
                status: .running,
                workspacePath: childWorkspacePath,
                inputs: childInputs
            )
            let childRun = try await store.createRun(childRunTemplate)

            // Create a child dispatcher sharing the same infrastructure.
            let childDispatcher = NodeDispatcher(
                plan: childPlan,
                providers: providers,
                store: store,
                parser: parser,
                templateResolver: templateResolver,
                expressionEvaluator: expressionEvaluator,
                evaluatorRunner: evaluatorRunner,
                interactiveHandler: interactiveHandler,
                loopHandler: loopHandler,
                maxParallelNodes: maxParallelNodes,
                repoRoot: repoRoot,
                environment: environment,
                onEvent: onEvent
            )

            // Execute the child workflow.
            let childResult = try await childDispatcher.execute(
                run: childRun,
                inputs: childInputs
            )

            // Handle child failure.
            if childResult.status == .failed {
                var childErrorDetail = "Child workflow failed"
                if let childExecs = try? await store.getNodeExecutions(
                    runID: childRun.id, nodeID: nil
                ) {
                    let failedNodes = childExecs.filter { $0.status == .failed }
                    let errorMessages = failedNodes.compactMap { exec -> String? in
                        guard let error = exec.error else { return nil }
                        return "[\(exec.nodeID)] \(error)"
                    }
                    if !errorMessages.isEmpty {
                        childErrorDetail = errorMessages.joined(separator: "; ")
                    }
                }
                try await store.updateNodeExecution(
                    id: execID, status: .failed, output: nil, error: childErrorDetail
                )
                throw EngineError.nestedWorkflowFailed(
                    nodeID: node.id, workflowFile: workflowFile,
                    detail: childErrorDetail
                )
            }

            // Extract child output.
            let childOutput: String
            if let runOutput = childResult.output {
                childOutput = runOutput
            } else {
                let childExecs = (try? await store.getNodeExecutions(
                    runID: childRun.id, nodeID: nil
                )) ?? []
                let lastCompleted = childExecs
                    .filter { $0.status == .completed && $0.output != nil }
                    .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
                    .last
                childOutput = lastCompleted?.output ?? ""
            }

            lastOutput = childOutput

            // Record iteration success.
            try await store.updateNodeExecution(
                id: execID, status: .completed, output: lastOutput, error: nil
            )

            // Run the evaluator.
            var evalOutputs = currentContext.outputs
            evalOutputs["last_output"] = lastOutput
            if let prev = previousOutput {
                evalOutputs["_previous_iteration_output"] = prev
            }
            let evalContext = TaskContext(
                inputs: currentContext.inputs,
                outputs: evalOutputs,
                nodeStatuses: currentContext.nodeStatuses,
                repoRoot: currentContext.repoRoot,
                workspacePath: currentContext.workspacePath,
                environment: currentContext.environment
            )

            let shouldStop: Bool
            do {
                shouldStop = try await evaluatorRunner.evaluate(
                    name: loopConfig.until,
                    lastOutput: lastOutput,
                    context: evalContext
                )
            } catch {
                throw EngineError.evaluatorFailed(
                    name: loopConfig.until,
                    detail: error.localizedDescription
                )
            }

            let evalResult = shouldStop ? "stopped" : "continuing"
            logger.info("[\(node.id)] iteration \(iteration) → \(evalResult)")

            if shouldStop {
                return lastOutput
            }

            // Prepare for next iteration.
            previousOutput = lastOutput
            var nextOutputs = currentContext.outputs
            nextOutputs["last_output"] = lastOutput
            currentContext = TaskContext(
                inputs: currentContext.inputs,
                outputs: nextOutputs,
                nodeStatuses: currentContext.nodeStatuses,
                repoRoot: currentContext.repoRoot,
                workspacePath: currentContext.workspacePath,
                environment: currentContext.environment
            )
        }

        throw EngineError.maxIterationsReached(nodeID: node.id, count: maxIterations)
    }

    // MARK: - Nested Workflow Execution

    /// Executes a nested (child) workflow referenced by a node's `workflow:` field.
    ///
    /// Parses the child workflow YAML, resolves the node's `inputs:` mapping,
    /// determines workspace path (shared vs isolated), plans and dispatches the
    /// child workflow's nodes, and returns the child's final output as this
    /// node's result.
    ///
    /// - Parameters:
    ///   - node: The parent node referencing the child workflow.
    ///   - run: The parent workflow run.
    ///   - context: The current execution context with resolved inputs/outputs.
    /// - Returns: A tuple of (nodeID, status, output, error).
    private func executeNestedWorkflow(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        config: ResolvedNodeConfig
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        guard let workflowFile = node.workflow else {
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: "nil", detail: "No workflow file specified"
            ))
        }

        let execID = UUID().uuidString

        // Create initial execution record.
        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            agent: "nested-workflow",
            startedAt: Date()
        )
        do {
            _ = try await store.createNodeExecution(exec)
        } catch {
            logger.warning("[\(node.id)] Failed to persist nested workflow execution: \(error)")
        }

        onEvent(.nodeStarted(nodeID: node.id, runID: run.id, agent: "nested-workflow"))

        logger.debug("nested workflow: \(workflowFile)")

        // 1. Parse the child workflow YAML.
        let childWorkflow: Workflow
        do {
            childWorkflow = try parser.parse(file: workflowFile)
        } catch {
            do {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: "Failed to parse child workflow '\(workflowFile)': \(error)"
                )
            } catch let storeError {
                logger.warning("[\(node.id)] Failed to persist parse failure: \(storeError)")
            }
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Parse failed: \(error)"
            ))
        }

        // 2. Resolve the node's inputs mapping — each value is a template string
        //    resolved against the parent's current context.
        var childInputs: [String: String] = [:]
        if let inputMappings = node.inputs {
            for (key, template) in inputMappings {
                do {
                    let resolved = try templateResolver.resolve(template: template, context: context)
                    childInputs[key] = resolved
                } catch {
                    do {
                        try await store.updateNodeExecution(
                            id: execID,
                            status: .failed,
                            output: nil,
                            error: "Failed to resolve input '\(key)': \(error)"
                        )
                    } catch let storeError {
                        logger.warning("[\(node.id)] Failed to persist input resolution failure: \(storeError)")
                    }
                    return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                        nodeID: node.id, workflowFile: workflowFile,
                        detail: "Input resolution failed for '\(key)': \(error)"
                    ))
                }
            }
        }

        // 2b. Validate that the parent provides all required inputs for the child.
        //     Inputs that have a default in the child workflow are exempt — they
        //     will be filled during the child's own default merging phase.
        for childInput in childWorkflow.input {
            if childInput.required && childInput.defaultValue == nil
                && childInputs[childInput.name] == nil
            {
                do {
                    try await store.updateNodeExecution(
                        id: execID,
                        status: .failed,
                        output: nil,
                        error: "Missing required input '\(childInput.name)' for child workflow '\(childWorkflow.name)'"
                    )
                } catch let storeError {
                    logger.warning("[\(node.id)] Failed to persist missing input failure: \(storeError)")
                }
                return (node.id, .failed, nil, EngineError.missingRequiredInput(
                    name: childInput.name, workflow: childWorkflow.name
                ))
            }
        }

        // 3. Determine workspace path based on workspace mode.
        //    shared (default): child uses parent's workspace path.
        //    isolated: child gets a sub-workspace directory.
        let childWorkspacePath: String
        let workspaceMode = config.workspaceMode ?? .shared

        switch workspaceMode {
        case .shared:
            childWorkspacePath = run.workspacePath
        case .isolated:
            let nestedDir = (run.workspacePath as NSString)
                .appendingPathComponent("nested")
            let nodeDir = (nestedDir as NSString)
                .appendingPathComponent(node.id)
            childWorkspacePath = nodeDir

            // Create the isolated workspace directory.
            do {
                try FileManager.default.createDirectory(
                    atPath: nodeDir,
                    withIntermediateDirectories: true
                )
            } catch {
                do {
                    try await store.updateNodeExecution(
                        id: execID,
                        status: .failed,
                        output: nil,
                        error: "Failed to create isolated workspace: \(error)"
                    )
                } catch let storeError {
                    logger.warning("[\(node.id)] Failed to persist workspace creation failure: \(storeError)")
                }
                return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                    nodeID: node.id, workflowFile: workflowFile,
                    detail: "Workspace creation failed: \(error)"
                ))
            }
        }

        // 4. Plan the child workflow.
        let childPlan: ExecutionPlan
        do {
            let planner = ExecutionPlanner()
            childPlan = try planner.plan(workflow: childWorkflow)
        } catch {
            do {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: "Failed to plan child workflow: \(error)"
                )
            } catch let storeError {
                logger.warning("[\(node.id)] Failed to persist planning failure: \(storeError)")
            }
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Planning failed: \(error)"
            ))
        }

        // 5. Create a child run record.
        let childRunTemplate = Run(
            id: "",
            workflowName: childWorkflow.name,
            workflowFile: workflowFile,
            status: .running,
            workspacePath: childWorkspacePath,
            inputs: childInputs
        )

        let childRun: Run
        do {
            childRun = try await store.createRun(childRunTemplate)
        } catch {
            do {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: "Failed to create child run: \(error)"
                )
            } catch let storeError {
                logger.warning("[\(node.id)] Failed to persist run creation failure: \(storeError)")
            }
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Run creation failed: \(error)"
            ))
        }

        // 6. Create a child dispatcher sharing the same providers, store, parser,
        //    template resolver, and expression evaluator.
        let childDispatcher = NodeDispatcher(
            plan: childPlan,
            providers: providers,
            store: store,
            parser: parser,
            templateResolver: templateResolver,
            expressionEvaluator: expressionEvaluator,
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: maxParallelNodes,
            repoRoot: repoRoot,
            environment: environment,
            onEvent: onEvent
        )

        // 7. Execute the child workflow.
        let childResult: Run
        do {
            childResult = try await childDispatcher.execute(
                run: childRun,
                inputs: childInputs
            )
        } catch {
            let detail = "Execution failed: \(error)"
            do {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: detail
                )
            } catch let storeError {
                logger.warning("[\(node.id)] Failed to persist child execution failure: \(storeError)")
            }
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: detail))
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: detail
            ))
        }

        // 8. If the child failed, the parent node fails.
        //    Query child executions to extract the actual root cause error.
        if childResult.status == .failed {
            logger.debug("nested workflow: \(workflowFile) failed")

            // Find the actual error from the child's failed node(s).
            var childErrorDetail = "Child workflow failed"
            if let childExecs = try? await store.getNodeExecutions(runID: childRun.id, nodeID: nil) {
                let failedNodes = childExecs.filter { $0.status == .failed }
                let errorMessages = failedNodes.compactMap { exec -> String? in
                    guard let error = exec.error else { return nil }
                    return "[\(exec.nodeID)] \(error)"
                }
                if !errorMessages.isEmpty {
                    childErrorDetail = errorMessages.joined(separator: "; ")
                }
            }

            do {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: childErrorDetail
                )
            } catch {
                logger.warning("[\(node.id)] Failed to persist child workflow failure: \(error)")
            }
            let error = EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: childErrorDetail
            )
            onEvent(.nodeFailed(nodeID: node.id, runID: run.id, error: childErrorDetail))
            return (node.id, .failed, nil, error)
        }

        // 9. Extract the child's output. Use the child run's output if it has one,
        //    otherwise use the last node's output from the child's execution records.
        let childOutput: String?
        if let runOutput = childResult.output {
            childOutput = runOutput
        } else {
            // Attempt to find the last completed node's output from child executions.
            let childExecs: [NodeExecution]
            do {
                childExecs = try await store.getNodeExecutions(
                    runID: childRun.id, nodeID: nil
                )
            } catch {
                logger.warning("[\(node.id)] Failed to fetch child executions: \(error)")
                childExecs = []
            }
            let lastCompleted = childExecs
                .filter { $0.status == .completed && $0.output != nil }
                .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
                .last
            childOutput = lastCompleted?.output
        }

        // 10. Record success on the parent node's execution.
        do {
            try await store.updateNodeExecution(
                id: execID,
                status: .completed,
                output: childOutput,
                error: nil
            )
        } catch {
            logger.warning("[\(node.id)] Failed to persist nested workflow success: \(error)")
        }

        logger.debug("nested workflow: \(workflowFile) completed")
        onEvent(.nodeCompleted(nodeID: node.id, runID: run.id, output: childOutput))
        return (node.id, .completed, childOutput, nil)
    }

    // MARK: - Config Resolution

    /// Resolves all `Resolvable` config fields on a node into concrete typed values.
    ///
    /// Called once per node before dispatching to any execution method. This ensures
    /// template expressions like `{{input.timeout}}` are resolved against the
    /// current context and converted to their target types.
    private func resolveNodeConfig(
        _ node: Models.Node, context: TaskContext
    ) throws -> ResolvedNodeConfig {
        let agent: String? = try node.agent.map {
            try templateResolver.resolve($0, context: context)
        }
        let timeoutSeconds: Int? = try node.timeoutSeconds.map {
            try templateResolver.resolve($0, context: context)
        }
        let onFailure = try templateResolver.resolve(node.onFailure, context: context)
        let workspaceMode: WorkspaceMode? = try node.workspaceMode.map {
            try templateResolver.resolve($0, context: context)
        }
        // Resolve provider-specific parameters (template strings → concrete values).
        var resolvedParameters: [String: String] = [:]
        for (key, resolvable) in node.parameters {
            resolvedParameters[key] = try templateResolver.resolve(resolvable, context: context)
        }

        let retry: ResolvedRetryConfig?
        if let r = node.retry {
            retry = ResolvedRetryConfig(
                maxAttempts: try templateResolver.resolve(r.maxAttempts, context: context),
                delaySeconds: try templateResolver.resolve(r.delaySeconds, context: context)
            )
        } else {
            retry = nil
        }

        let loop: ResolvedLoopConfig?
        if let l = node.loop {
            loop = ResolvedLoopConfig(
                until: l.until,
                maxIterations: try templateResolver.resolve(l.maxIterations, context: context),
                freshContext: try templateResolver.resolve(l.freshContext, context: context)
            )
        } else {
            loop = nil
        }

        return ResolvedNodeConfig(
            agent: agent, timeoutSeconds: timeoutSeconds, onFailure: onFailure,
            workspaceMode: workspaceMode, parameters: resolvedParameters,
            retry: retry, loop: loop
        )
    }

    // MARK: - Dependency Checking

    /// Returns true if all of a node's dependencies are satisfied.
    ///
    /// A node is ready if:
    /// - It has no dependencies, OR
    /// - At least one dependency is completed or failed-with-continue strategy
    /// - No dependency has .stop strategy and is failed
    /// - Not all dependencies are skipped (if all skipped, node should be skipped too)
    private func isNodeReady(
        nodeID: String,
        nodeStatuses: [String: NodeStatus],
        resolvedOnFailure: [String: FailureStrategy]
    ) -> Bool {
        guard let node = plan.nodesByID[nodeID] else { return false }

        // Nodes with no dependencies are always ready.
        if node.dependsOn.isEmpty {
            return true
        }

        // Check each dependency.
        var allResolved = true
        var allSkipped = true
        var hasBlockingFailure = false

        for depID in node.dependsOn {
            guard let depStatus = nodeStatuses[depID] else {
                // Dependency hasn't been processed yet.
                allResolved = false
                allSkipped = false
                continue
            }

            switch depStatus {
            case .completed:
                allSkipped = false
            case .skipped:
                break
            case .failed:
                allSkipped = false
                let strategy = resolvedOnFailure[depID] ?? .stop
                switch strategy {
                case .stop:
                    hasBlockingFailure = true
                case .skip:
                    // Skip strategy: the dependent is handled by skipDependents.
                    break
                case .continue:
                    // Continue strategy: the dependent can still run.
                    break
                }
            case .cancelled:
                allSkipped = false
                hasBlockingFailure = true
            default:
                // Still running or pending.
                allResolved = false
                allSkipped = false
            }
        }

        if !allResolved { return false }
        if hasBlockingFailure { return false }
        if allSkipped { return false }

        return true
    }

    // MARK: - Skip Propagation

    /// Marks dependents of a failed-with-skip node as skipped, but only if ALL
    /// of a dependent's upstream dependencies are either skipped or failed-with-skip.
    ///
    /// Per spec: "A node runs if at least one dependency is satisfied; it is
    /// skipped only if all dependencies were skipped." This prevents unconditional
    /// cascading when a node has other satisfied (completed / failed-with-continue)
    /// dependencies.
    private func skipDependents(
        of nodeID: String,
        run: Run,
        pendingNodes: inout Set<String>,
        nodeStatuses: inout [String: NodeStatus],
        resolvedOnFailure: [String: FailureStrategy]
    ) {
        guard let deps = plan.dependents[nodeID] else { return }

        for depID in deps where pendingNodes.contains(depID) {
            guard let depNode = plan.nodesByID[depID] else { continue }

            // Only skip if ALL of this dependent's upstream dependencies are
            // in a non-satisfying terminal state (skipped or failed-with-skip).
            let allDepsUnsatisfied = depNode.dependsOn.allSatisfy { upstreamID in
                guard let status = nodeStatuses[upstreamID] else { return false }
                switch status {
                case .skipped:
                    return true
                case .failed:
                    // A failed dep with on_failure: .skip counts as unsatisfied.
                    // Use the runtime-resolved strategy rather than the raw
                    // Resolvable, which may be a .template expression.
                    return resolvedOnFailure[upstreamID] == .skip
                default:
                    return false
                }
            }

            if allDepsUnsatisfied {
                nodeStatuses[depID] = .skipped
                pendingNodes.remove(depID)
                onEvent(.nodeSkipped(nodeID: depID, runID: run.id))

                // Recursively check transitive dependents.
                skipDependents(
                    of: depID, run: run, pendingNodes: &pendingNodes,
                    nodeStatuses: &nodeStatuses, resolvedOnFailure: resolvedOnFailure
                )
            }
        }
    }

    /// Cascades skips from a skipped node: if ALL of a dependent's deps are skipped,
    /// the dependent is also skipped.
    private func cascadeSkips(
        from nodeID: String,
        run: Run,
        pendingNodes: inout Set<String>,
        nodeStatuses: inout [String: NodeStatus]
    ) {
        guard let deps = plan.dependents[nodeID] else { return }

        for depID in deps where pendingNodes.contains(depID) {
            guard let depNode = plan.nodesByID[depID] else { continue }

            // Check if ALL of this node's dependencies are skipped.
            let allDepsSkipped = depNode.dependsOn.allSatisfy { upstreamID in
                nodeStatuses[upstreamID] == .skipped
            }

            if allDepsSkipped {
                nodeStatuses[depID] = .skipped
                pendingNodes.remove(depID)
                onEvent(.nodeSkipped(nodeID: depID, runID: run.id))

                // Recursively cascade.
                cascadeSkips(from: depID, run: run, pendingNodes: &pendingNodes, nodeStatuses: &nodeStatuses)
            }
        }
    }
}
