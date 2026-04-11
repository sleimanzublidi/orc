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

    private let logger = Logger(label: "orc.engine.dispatcher")

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
                    nodeStatuses: nodeStatuses
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

            // Snapshot mutable state before entering the task group so the
            // closure captures immutable copies (required by strict concurrency).
            let snapshotOutputs = nodeOutputs
            let snapshotStatuses = nodeStatuses

            // Execute the batch using a TaskGroup.
            let results: [(String, NodeStatus, String?, (any Error)?)] =
                try await withThrowingTaskGroup(
                    of: (String, NodeStatus, String?, (any Error)?).self
                ) { group in
                    for nodeID in batch {
                        group.addTask {
                            try await self.executeNode(
                                nodeID: nodeID,
                                run: run,
                                inputs: inputs,
                                nodeOutputs: snapshotOutputs,
                                nodeStatuses: snapshotStatuses
                            )
                        }
                    }

                    var collected: [(String, NodeStatus, String?, (any Error)?)] = []
                    for try await result in group {
                        collected.append(result)
                    }
                    return collected
                }

            // Apply results to our state.
            for (nodeID, status, output, _) in results {
                nodeStatuses[nodeID] = status
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
                    let node = plan.nodesByID[nodeID]
                    let strategy = node?.onFailure ?? .stop

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
                            _ = try? await store.createNodeExecution(exec)
                        }
                        pendingNodes.removeAll()

                    case .skip:
                        // Skip dependents: mark all downstream nodes as skipped.
                        skipDependents(
                            of: nodeID,
                            pendingNodes: &pendingNodes,
                            nodeStatuses: &nodeStatuses
                        )

                    case .continue:
                        // Continue: downstream nodes can still run.
                        break
                    }
                } else if status == .skipped {
                    // Propagate skip to dependents if all their deps are skipped.
                    cascadeSkips(
                        from: nodeID,
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
                inputs: inputs,
                outputs: nodeOutputs,
                nodeStatuses: nodeStatuses,
                workspacePath: run.workspacePath
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
    /// - Returns: A tuple of (nodeID, status, output, error).
    private func executeNode(
        nodeID: String,
        run: Run,
        inputs: [String: String],
        nodeOutputs: [String: String],
        nodeStatuses: [String: NodeStatus]
    ) async throws -> (String, NodeStatus, String?, (any Error)?) {
        guard let node = plan.nodesByID[nodeID] else {
            return (nodeID, .failed, nil, EngineError.dependencyFailed(nodeID: nodeID, upstream: "node not found"))
        }

        logger.info("[\(nodeID)] running...")

        let context = TaskContext(
            inputs: inputs,
            outputs: nodeOutputs,
            nodeStatuses: nodeStatuses,
            workspacePath: run.workspacePath
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
                    return (nodeID, .skipped, nil, nil)
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
                return (nodeID, .failed, nil, error)
            }
        }

        // Handle interactive nodes.
        if let interactive = node.interactive {
            return await executeInteractiveNode(
                node: node, interactive: interactive, run: run, context: context
            )
        }

        // Handle loop nodes.
        if let loopConfig = node.loop {
            return await executeLoopNode(
                node: node, loopConfig: loopConfig, run: run, context: context
            )
        }

        // Handle nested workflow nodes.
        if node.workflow != nil {
            return await executeNestedWorkflow(node: node, run: run, context: context)
        }

        // Standard single-execution node.
        return await executeSingleNode(node: node, run: run, context: context)
    }

    /// Executes a standard (non-loop, non-interactive) node.
    private func executeSingleNode(
        node: Models.Node,
        run: Run,
        context: TaskContext
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        let execID = UUID().uuidString
        let agentName = node.agent ?? "shell"

        // Resolve the prompt/command template.
        let resolvedPrompt: String
        do {
            if let command = node.command {
                resolvedPrompt = try templateResolver.resolve(template: command, context: context)
            } else if let prompt = node.prompt {
                resolvedPrompt = try templateResolver.resolve(template: prompt, context: context)
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
            _ = try? await store.createNodeExecution(exec)
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
        _ = try? await store.createNodeExecution(exec)

        // Execute with retry support.
        let maxAttempts = node.retry?.maxAttempts ?? 1
        var lastError: (any Error)?

        for attempt in 1...maxAttempts {
            do {
                let provider = try providers.provider(named: agentName)
                let output = try await provider.execute(prompt: resolvedPrompt, context: context, timeout: node.timeoutSeconds)

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
                    if let delay = node.retry?.delaySeconds, delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    }
                }
            }
        }

        // All attempts exhausted.
        try? await store.updateNodeExecution(
            id: execID,
            status: .failed,
            output: nil,
            error: lastError?.localizedDescription
        )

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
        context: TaskContext
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
            agent: node.agent,
            message: message,
            tmuxSession: sessionName,
            startedAt: Date()
        )
        _ = try? await store.createNodeExecution(exec)

        switch interactive {
        case .session:
            // sessionName is guaranteed non-nil in the .session branch.
            let resolvedSessionName = sessionName!
            let maxAttempts = node.retry?.maxAttempts ?? 1
            var lastError: (any Error)?

            for attempt in 1...maxAttempts {
                do {
                    let output = try await interactiveHandler.handleSession(
                        node: node, run: run, context: context,
                        sessionName: resolvedSessionName, nodeExecutionID: execID
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
                        if let delay = node.retry?.delaySeconds, delay > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        }
                    }
                }
            }

            // All retry attempts exhausted.
            try? await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: lastError?.localizedDescription
            )
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
                try? await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: error.localizedDescription
                )
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
        loopConfig: LoopConfig,
        run: Run,
        context: TaskContext
    ) async -> (String, NodeStatus, String?, (any Error)?) {
        let maxAttempts = node.retry?.maxAttempts ?? 1
        var lastError: (any Error)?

        for attempt in 1...maxAttempts {
            do {
                let output = try await loopHandler.executeLoop(
                    node: node, run: run, context: context, loopConfig: loopConfig
                )
                return (node.id, .completed, output.output, nil)
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    if let delay = node.retry?.delaySeconds, delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    }
                }
            }
        }

        return (node.id, .failed, nil, lastError)
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
        context: TaskContext
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
        _ = try? await store.createNodeExecution(exec)

        // 1. Parse the child workflow YAML.
        let childWorkflow: Workflow
        do {
            childWorkflow = try parser.parse(file: workflowFile)
        } catch {
            try? await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: "Failed to parse child workflow '\(workflowFile)': \(error)"
            )
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
                    try? await store.updateNodeExecution(
                        id: execID,
                        status: .failed,
                        output: nil,
                        error: "Failed to resolve input '\(key)': \(error)"
                    )
                    return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                        nodeID: node.id, workflowFile: workflowFile,
                        detail: "Input resolution failed for '\(key)': \(error)"
                    ))
                }
            }
        }

        // 3. Determine workspace path based on workspace mode.
        //    shared (default): child uses parent's workspace path.
        //    isolated: child gets a sub-workspace directory.
        let childWorkspacePath: String
        let workspaceMode = node.workspaceMode ?? .shared

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
                try? await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: "Failed to create isolated workspace: \(error)"
                )
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
            try? await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: "Failed to plan child workflow: \(error)"
            )
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
            try? await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: "Failed to create child run: \(error)"
            )
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
            maxParallelNodes: maxParallelNodes
        )

        // 7. Execute the child workflow.
        let childResult: Run
        do {
            childResult = try await childDispatcher.execute(
                run: childRun,
                inputs: childInputs
            )
        } catch {
            try? await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: "Child workflow execution failed: \(error)"
            )
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Execution failed: \(error)"
            ))
        }

        // 8. If the child failed, the parent node fails.
        if childResult.status == .failed {
            try? await store.updateNodeExecution(
                id: execID,
                status: .failed,
                output: nil,
                error: "Child workflow completed with status: failed"
            )
            return (node.id, .failed, nil, EngineError.nestedWorkflowFailed(
                nodeID: node.id, workflowFile: workflowFile,
                detail: "Child workflow failed"
            ))
        }

        // 9. Extract the child's output. Use the child run's output if it has one,
        //    otherwise use the last node's output from the child's execution records.
        let childOutput: String?
        if let runOutput = childResult.output {
            childOutput = runOutput
        } else {
            // Attempt to find the last completed node's output from child executions.
            let childExecs = (try? await store.getNodeExecutions(
                runID: childRun.id, nodeID: nil
            )) ?? []
            let lastCompleted = childExecs
                .filter { $0.status == .completed && $0.output != nil }
                .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
                .last
            childOutput = lastCompleted?.output
        }

        // 10. Record success on the parent node's execution.
        try? await store.updateNodeExecution(
            id: execID,
            status: .completed,
            output: childOutput,
            error: nil
        )

        return (node.id, .completed, childOutput, nil)
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
        nodeStatuses: [String: NodeStatus]
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
                let depNode = plan.nodesByID[depID]
                let strategy = depNode?.onFailure ?? .stop
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
        pendingNodes: inout Set<String>,
        nodeStatuses: inout [String: NodeStatus]
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
                    let upNode = plan.nodesByID[upstreamID]
                    return upNode?.onFailure == .skip
                default:
                    return false
                }
            }

            if allDepsUnsatisfied {
                nodeStatuses[depID] = .skipped
                pendingNodes.remove(depID)

                // Recursively check transitive dependents.
                skipDependents(of: depID, pendingNodes: &pendingNodes, nodeStatuses: &nodeStatuses)
            }
        }
    }

    /// Cascades skips from a skipped node: if ALL of a dependent's deps are skipped,
    /// the dependent is also skipped.
    private func cascadeSkips(
        from nodeID: String,
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

                // Recursively cascade.
                cascadeSkips(from: depID, pendingNodes: &pendingNodes, nodeStatuses: &nodeStatuses)
            }
        }
    }
}
