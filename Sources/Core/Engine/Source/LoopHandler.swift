import Foundation
import Logging
import Models
import Providers
import Template

/// Manages sequential loop iterations for nodes with a `loop` configuration.
///
/// Each iteration invokes the provider, captures output, runs the evaluator,
/// and checks `max_iterations`. The loop exits when the evaluator returns true
/// or the iteration limit is reached.
struct LoopHandler: Sendable {
    let providers: ProviderRegistry
    let store: any WorkflowStoring
    let evaluatorRunner: EvaluatorRunner
    let templateResolver: any TemplateResolving
    let tmux: any TmuxProviding

    private let logger = Logger(label: "orc.engine.loop")

    /// Executes a loop node, iterating until the evaluator returns true or max_iterations is hit.
    ///
    /// Supports retry logic per iteration (H8), interactive session loops (H7),
    /// and acknowledges the `fresh_context` flag (H5).
    ///
    /// - Parameters:
    ///   - node: The node definition with its loop configuration.
    ///   - run: The current workflow run.
    ///   - context: The accumulated task context (inputs, outputs, workspace path).
    ///   - loopConfig: The loop configuration (until evaluator, max_iterations, fresh_context).
    /// - Returns: The output from the final iteration.
    /// - Throws: `EngineError.maxIterationsReached` if the loop exhausts all iterations
    ///   without the evaluator returning true.
    func executeLoop(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        loopConfig: LoopConfig
    ) async throws -> TaskOutput {
        let provider = try providers.provider(named: node.agent ?? "shell")

        // H5: Acknowledge fresh_context flag. All current providers are stateless
        // (each invocation spawns a new process), so fresh_context: true is the
        // effective default. When fresh_context is false, the intent is to let AI
        // agents maintain conversation context across iterations — but no current
        // provider supports persistent sessions, so we log a warning.
        if !loopConfig.freshContext {
            logger.warning(
                "fresh_context: false requested for loop node '\(node.id)', but all current providers are stateless — conversation context will not persist across iterations"
            )
        }

        var lastOutput = ""
        var previousOutput: String? = nil
        var currentContext = context

        for iteration in 1...loopConfig.maxIterations {
            // Check for task cancellation before each iteration.
            try Task.checkCancellation()

            // Resolve the prompt template with current context (includes {{last_output}}).
            let resolvedPrompt: String
            if let prompt = node.prompt {
                resolvedPrompt = try templateResolver.resolve(template: prompt, context: currentContext)
            } else {
                resolvedPrompt = ""
            }

            // Record the iteration in the store.
            let execID = UUID().uuidString
            let execution = NodeExecution(
                id: execID,
                runID: run.id,
                nodeID: node.id,
                status: .running,
                agent: node.agent,
                attempt: 1,
                iteration: iteration,
                prompt: resolvedPrompt,
                startedAt: Date()
            )
            _ = try await store.createNodeExecution(execution)

            // H8: Execute with retry support, wrapping both standard and interactive modes.
            let output: TaskOutput
            do {
                output = try await executeIterationWithRetry(
                    node: node, run: run, provider: provider,
                    resolvedPrompt: resolvedPrompt, context: currentContext,
                    iteration: iteration, execID: execID
                )
            } catch {
                try await store.updateNodeExecution(
                    id: execID,
                    status: .failed,
                    output: nil,
                    error: error.localizedDescription
                )
                throw error
            }

            lastOutput = output.output

            // Record iteration output.
            try await store.updateNodeExecution(
                id: execID,
                status: .completed,
                output: lastOutput,
                error: nil
            )

            // Build context for evaluator: set {{last_output}} and the internal
            // _previous_iteration_output key for the output_unchanged evaluator.
            var evalOutputs = currentContext.outputs
            evalOutputs["last_output"] = lastOutput
            if let prev = previousOutput {
                evalOutputs["_previous_iteration_output"] = prev
            }
            let evalContext = TaskContext(
                inputs: currentContext.inputs,
                outputs: evalOutputs,
                nodeStatuses: currentContext.nodeStatuses,
                workspacePath: currentContext.workspacePath
            )

            // Run the evaluator. If it throws, treat as node failure (not "false").
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

            if shouldStop {
                return TaskOutput(output: lastOutput, exitStatus: output.exitStatus)
            }

            // Prepare for next iteration.
            previousOutput = lastOutput

            // Update context for next iteration with fresh last_output.
            var nextOutputs = currentContext.outputs
            nextOutputs["last_output"] = lastOutput
            currentContext = TaskContext(
                inputs: currentContext.inputs,
                outputs: nextOutputs,
                nodeStatuses: currentContext.nodeStatuses,
                workspacePath: currentContext.workspacePath
            )
        }

        throw EngineError.maxIterationsReached(
            nodeID: node.id,
            count: loopConfig.maxIterations
        )
    }

    // MARK: - Private Helpers

    /// Executes a single loop iteration with retry support, handling both standard
    /// and interactive (session) execution modes.
    ///
    /// H7: If the node has `interactive: .session`, uses `executeInteractive` with
    /// a per-iteration tmux session name. Prompt-interactive loops are not yet
    /// supported (they require the full dispatcher awaiting_input flow).
    ///
    /// H8: Wraps execution in retry logic from the node's retry config.
    private func executeIterationWithRetry(
        node: Models.Node,
        run: Run,
        provider: any AgentProviding,
        resolvedPrompt: String,
        context: TaskContext,
        iteration: Int,
        execID: String
    ) async throws -> TaskOutput {
        let maxAttempts = node.retry?.maxAttempts ?? 1
        var lastError: (any Error)?

        for attempt in 1...maxAttempts {
            do {
                // H7: Check if this is an interactive session loop node.
                if case .session = node.interactive {
                    let sessionName = "orc-\(run.id)-\(node.id)-iter\(iteration)"
                    let interactiveOutput = try await provider.executeInteractive(
                        prompt: resolvedPrompt,
                        context: context,
                        sessionName: sessionName,
                        timeout: node.timeoutSeconds
                    )

                    // Poll until the tmux session exits, similar to InteractiveHandler.
                    while !Task.isCancelled {
                        let exists = try await tmux.sessionExists(name: sessionName)
                        if !exists { break }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    try Task.checkCancellation()

                    // Capture session output.
                    let capturedText: String
                    do {
                        capturedText = try await tmux.captureOutput(name: sessionName)
                    } catch {
                        capturedText = ""
                    }

                    return TaskOutput(output: capturedText, exitStatus: interactiveOutput.exitStatus)
                } else if case .prompt = node.interactive {
                    // Prompt-interactive loops require the full dispatcher
                    // awaiting_input flow which cannot be driven from within
                    // the loop handler. Log a warning and fall through to
                    // standard execution.
                    logger.warning(
                        "interactive: prompt is not supported inside loop nodes; node '\(node.id)' iteration \(iteration) will use standard execution"
                    )
                }

                // Standard (non-interactive) execution.
                return try await provider.execute(
                    prompt: resolvedPrompt, context: context, timeout: node.timeoutSeconds
                )
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
        throw lastError!
    }
}
