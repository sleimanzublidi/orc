import Foundation
import Logging
import Models
import Providers

/// Manages interactive nodes in both session and prompt modes.
///
/// - **Session mode**: delegates to the provider's `executeInteractive` method,
///   which typically starts a tmux session, then polls until the session exits
///   and captures its output.
/// - **Prompt mode**: sets the node to `awaiting_input` status and waits for
///   a response via the `respond` method.
struct InteractiveHandler: Sendable {
    let store: any WorkflowStoring
    let providers: ProviderRegistry
    let tmux: any TmuxProviding
    let templateResolver: any TemplateResolving

    private let logger = Logger(label: "orc.engine.interactive")

    /// How often to check whether the tmux session still exists (in seconds).
    static let pollIntervalSeconds: UInt64 = 1

    /// Handles a session-mode interactive node by delegating to the provider,
    /// then polling until the tmux session exits and capturing its output.
    ///
    /// Lifecycle:
    /// 1. The provider's `executeInteractive` creates the tmux session and returns immediately.
    /// 2. The node execution is set to `awaiting_input` so the CLI shows it as interactive.
    /// 3. A polling loop waits until the tmux session no longer exists (the user finished
    ///    or the process inside exited).
    /// 4. The pane output is captured via `TmuxProviding.captureOutput`. If the session
    ///    was already cleaned up, capture failure is tolerated and empty output is returned.
    ///
    /// - Parameters:
    ///   - node: The interactive node definition.
    ///   - run: The current workflow run.
    ///   - context: The accumulated task context.
    ///   - sessionName: The tmux session name to create.
    ///   - nodeExecutionID: The ID of the node execution record to update.
    ///   - agentName: The resolved agent name for provider lookup.
    /// - Returns: The output from the interactive session.
    func handleSession(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        sessionName: String,
        nodeExecutionID: String,
        agentName: String = "shell"
    ) async throws -> TaskOutput {
        let provider = try providers.provider(named: agentName)

        // H6: Resolve {{variables}} in the prompt before passing to the provider.
        // Without this, raw template strings like "{{some_var}}" would be sent
        // unresolved to the interactive session.
        let rawPrompt = node.prompt ?? ""
        let prompt = try templateResolver.resolve(template: rawPrompt, context: context)

        // Step 1: Create the tmux session via the provider.
        _ = try await provider.executeInteractive(
            prompt: prompt,
            context: context,
            sessionName: sessionName,
            timeout: nil
        )

        // Step 2: Mark the node as awaiting_input so the CLI knows the user
        // can attach to the session.
        try await store.updateNodeExecution(
            id: nodeExecutionID,
            status: .awaitingInput,
            output: nil,
            error: nil
        )
        try await store.updateRunStatus(id: run.id, status: .awaitingInput)

        logger.info("Interactive session '\(sessionName)' created, waiting for exit")

        // Step 3: Poll until the tmux session no longer exists.
        while !Task.isCancelled {
            let exists = try await tmux.sessionExists(name: sessionName)
            if !exists {
                break
            }
            try await Task.sleep(nanoseconds: Self.pollIntervalSeconds * 1_000_000_000)
        }

        // If the task was cancelled, propagate cancellation.
        try Task.checkCancellation()

        // Step 4: Attempt to capture the pane output. The session may already
        // be fully destroyed, so capture failure is tolerated.
        let capturedText: String
        do {
            capturedText = try await tmux.captureOutput(name: sessionName)
        } catch {
            logger.debug("Could not capture tmux output for '\(sessionName)': \(error)")
            capturedText = ""
        }

        logger.info("Interactive session '\(sessionName)' exited, captured \(capturedText.count) chars")

        return TaskOutput(output: capturedText, exitStatus: 0)
    }

    /// Handles a prompt-mode interactive node by setting its status to awaiting_input.
    ///
    /// The node execution record is updated with the prompt message and set to
    /// `awaiting_input` status. The caller must wait for a response via `respond`.
    ///
    /// - Parameters:
    ///   - node: The interactive node definition.
    ///   - run: The current workflow run.
    ///   - nodeExecutionID: The ID of the node execution record.
    func handlePrompt(
        node: Models.Node,
        run: Run,
        nodeExecutionID: String
    ) async throws {
        let message: String
        if case .prompt(let msg) = node.interactive {
            message = msg
        } else {
            message = ""
        }

        try await store.updateNodeExecution(
            id: nodeExecutionID,
            status: .awaitingInput,
            output: nil,
            error: nil
        )

        // Also update the run status to awaiting_input so the CLI knows.
        try await store.updateRunStatus(id: run.id, status: .awaitingInput)

        // Store the message in a separate field if needed. The message is already
        // stored in the node execution's `message` field from creation.
        _ = message  // Stored at creation time via NodeExecution init.
    }

    /// Provides a response to a node that is awaiting input.
    ///
    /// - Parameters:
    ///   - runID: The run ID containing the awaiting node.
    ///   - nodeID: The node ID to respond to.
    ///   - response: The user's response text.
    /// - Throws: `EngineError.nodeNotAwaitingInput` if the node is not in awaiting_input status.
    func respond(
        runID: String,
        nodeID: String,
        response: String
    ) async throws {
        let executions = try await store.getNodeExecutions(runID: runID, nodeID: nodeID)

        guard let execution = executions.last,
              execution.status == .awaitingInput
        else {
            let currentStatus = executions.last?.status ?? .pending
            throw EngineError.nodeNotAwaitingInput(nodeID: nodeID, status: currentStatus)
        }

        // Set the response as the node output and mark completed.
        try await store.updateNodeExecution(
            id: execution.id,
            status: .completed,
            output: response,
            error: nil
        )
    }
}
