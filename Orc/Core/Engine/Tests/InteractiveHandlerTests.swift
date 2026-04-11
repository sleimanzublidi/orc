import Testing
import Foundation
import Models
import Providers
@testable import Template
@testable import Engine

/// Tests for InteractiveHandler — prompt mode set/respond cycle and
/// session mode create/wait/capture lifecycle.
struct InteractiveHandlerTests {

    // MARK: - Helpers

    private func makeHandler(
        store: FakeWorkflowStore = FakeWorkflowStore(),
        tmux: FakeTmuxProvider = FakeTmuxProvider()
    ) -> (InteractiveHandler, FakeWorkflowStore, FakeAgentProvider, FakeTmuxProvider) {
        let fakeProvider = FakeAgentProvider(name: "fake")
        let registry = ProviderRegistry(providers: [fakeProvider])

        let handler = InteractiveHandler(
            store: store,
            providers: registry,
            tmux: tmux,
            templateResolver: TemplateResolver()
        )

        return (handler, store, fakeProvider, tmux)
    }

    private func makeRun(store: FakeWorkflowStore) async throws -> Run {
        let run = Run(
            id: "test-run",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        return try await store.createRun(run)
    }

    // MARK: - Prompt Mode

    @Test("handlePrompt sets node to awaiting_input")
    func handlePromptSetsAwaitingInput() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _, _) = makeHandler(store: store)
        let run = try await makeRun(store: store)

        let node = Models.Node(
            id: "prompt-node",
            agent: "fake",
            prompt: "Question?",
            interactive: .prompt(message: "Please approve")
        )

        // Create a node execution that the handler will update.
        let execID = "exec-1"
        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        try await handler.handlePrompt(node: node, run: run, nodeExecutionID: execID)

        // Verify the node execution is now awaiting_input.
        let executions = try await store.getNodeExecutions(runID: run.id, nodeID: node.id)
        #expect(executions.last?.status == .awaitingInput)

        // Verify the run is also set to awaiting_input.
        let updatedRun = try await store.getRun(id: run.id)
        #expect(updatedRun?.status == .awaitingInput)
    }

    @Test("respond sets node output and completes it")
    func respondSetsOutputAndCompletes() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _, _) = makeHandler(store: store)
        let run = try await makeRun(store: store)

        // Create an awaiting_input node execution.
        let execID = "exec-1"
        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: "prompt-node",
            status: .awaitingInput,
            message: "Please approve",
            startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        try await handler.respond(
            runID: run.id,
            nodeID: "prompt-node",
            response: "yes, approved"
        )

        // Verify the node execution is now completed with the response.
        let executions = try await store.getNodeExecutions(runID: run.id, nodeID: "prompt-node")
        let last = executions.last
        #expect(last?.status == .completed)
        #expect(last?.output == "yes, approved")
    }

    @Test("respond throws when node is not awaiting input")
    func respondThrowsWhenNotAwaiting() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _, _) = makeHandler(store: store)
        let run = try await makeRun(store: store)

        // Create a completed node execution (not awaiting input).
        let exec = NodeExecution(
            id: "exec-1",
            runID: run.id,
            nodeID: "prompt-node",
            status: .completed,
            startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        await #expect(throws: EngineError.self) {
            try await handler.respond(
                runID: run.id,
                nodeID: "prompt-node",
                response: "too late"
            )
        }
    }

    // MARK: - Session Mode

    @Test("handleSession creates session, waits for exit, and captures output")
    func handleSessionCreatesAndCaptures() async throws {
        let store = FakeWorkflowStore()
        let tmux = FakeTmuxProvider()
        // Session exists for 2 polls, then disappears.
        tmux.existsCheckCount = 2
        tmux.capturedOutput = "session output text"

        let (handler, _, fakeProvider, _) = makeHandler(store: store, tmux: tmux)
        let run = try await makeRun(store: store)

        let node = Models.Node(
            id: "session-node",
            agent: "fake",
            prompt: "start session",
            interactive: .session
        )
        let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/workspace")

        // Create a node execution record for the handler to update.
        let execID = "exec-session-1"
        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        let output = try await handler.handleSession(
            node: node, run: run, context: context,
            sessionName: "test-session", nodeExecutionID: execID
        )

        // The provider's executeInteractive should have been called.
        #expect(fakeProvider.interactiveCalls.count == 1)
        #expect(fakeProvider.interactiveCalls[0].sessionName == "test-session")

        // The node should have been set to awaiting_input during the session.
        let executions = try await store.getNodeExecutions(runID: run.id, nodeID: node.id)
        #expect(executions.last?.status == .awaitingInput)

        // The run should have been set to awaiting_input.
        let updatedRun = try await store.getRun(id: run.id)
        #expect(updatedRun?.status == .awaitingInput)

        // sessionExists was polled the expected number of times.
        #expect(tmux.sessionExistsCallCount == 3) // 2 true + 1 false

        // captureOutput was called once.
        #expect(tmux.captureOutputCallCount == 1)

        // The captured output is returned.
        #expect(output.output == "session output text")
        #expect(output.exitStatus == 0)
    }

    @Test("handleSession returns empty output when capture fails (session already gone)")
    func handleSessionReturnsEmptyOnCaptureFail() async throws {
        let store = FakeWorkflowStore()
        let tmux = FakeTmuxProvider()
        // Session exits immediately.
        tmux.existsCheckCount = 0
        tmux.captureError = ProviderError.tmuxFailure(
            session: "test-session", detail: "no such session"
        )

        let (handler, _, _, _) = makeHandler(store: store, tmux: tmux)
        let run = try await makeRun(store: store)

        let node = Models.Node(
            id: "session-node",
            agent: "fake",
            prompt: "start session",
            interactive: .session
        )
        let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/workspace")

        let execID = "exec-session-2"
        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        let output = try await handler.handleSession(
            node: node, run: run, context: context,
            sessionName: "test-session", nodeExecutionID: execID
        )

        // Capture failed, so output is empty — not an error.
        #expect(output.output == "")
        #expect(output.exitStatus == 0)
    }

    @Test("handleSession session exits immediately returns captured output")
    func handleSessionImmediateExit() async throws {
        let store = FakeWorkflowStore()
        let tmux = FakeTmuxProvider()
        // Session doesn't exist on first check.
        tmux.existsCheckCount = 0
        tmux.capturedOutput = "quick exit output"

        let (handler, _, _, _) = makeHandler(store: store, tmux: tmux)
        let run = try await makeRun(store: store)

        let node = Models.Node(
            id: "session-node",
            agent: "fake",
            prompt: "fast task",
            interactive: .session
        )
        let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/workspace")

        let execID = "exec-session-3"
        let exec = NodeExecution(
            id: execID,
            runID: run.id,
            nodeID: node.id,
            status: .running,
            startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        let output = try await handler.handleSession(
            node: node, run: run, context: context,
            sessionName: "fast-session", nodeExecutionID: execID
        )

        // Only 1 sessionExists check (returned false immediately).
        #expect(tmux.sessionExistsCallCount == 1)
        #expect(output.output == "quick exit output")
    }
}
