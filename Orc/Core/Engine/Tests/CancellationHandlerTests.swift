import Testing
import Foundation
import Models
@testable import Engine

/// Tests for CancellationHandler — cancelling runs and marking node executions.
struct CancellationHandlerTests {

    // MARK: - Helpers

    private func makeHandler(
        store: FakeWorkflowStore = FakeWorkflowStore(),
        tmux: FakeTmuxProvider = FakeTmuxProvider()
    ) -> (CancellationHandler, FakeWorkflowStore, FakeTmuxProvider) {
        let handler = CancellationHandler(store: store, tmux: tmux)
        return (handler, store, tmux)
    }

    // MARK: - Cancel Running Run

    @Test("Cancel marks running run as cancelled")
    func cancelRunningRun() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _) = makeHandler(store: store)

        let run = Run(
            id: "run-1",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        try await handler.cancel(runID: "run-1")

        let updated = try await store.getRun(id: "run-1")
        #expect(updated?.status == .cancelled)
    }

    @Test("Cancel marks pending node executions as cancelled")
    func cancelMarksPendingNodesAsCancelled() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _) = makeHandler(store: store)

        let run = Run(
            id: "run-1",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        // Create some node executions with different statuses.
        let completed = NodeExecution(id: "exec-1", runID: "run-1", nodeID: "A", status: .completed)
        let pending = NodeExecution(id: "exec-2", runID: "run-1", nodeID: "B", status: .pending)
        let running = NodeExecution(id: "exec-3", runID: "run-1", nodeID: "C", status: .running)

        _ = try await store.createNodeExecution(completed)
        _ = try await store.createNodeExecution(pending)
        _ = try await store.createNodeExecution(running)

        try await handler.cancel(runID: "run-1")

        let executions = try await store.getNodeExecutions(runID: "run-1", nodeID: nil)
        let execByNode = Dictionary(uniqueKeysWithValues: executions.map { ($0.nodeID, $0) })

        // Completed should remain completed.
        #expect(execByNode["A"]?.status == .completed)
        // Pending and running should be cancelled.
        #expect(execByNode["B"]?.status == .cancelled)
        #expect(execByNode["C"]?.status == .cancelled)
    }

    @Test("Cancel is a no-op for already-completed runs")
    func cancelCompletedRunIsNoop() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _) = makeHandler(store: store)

        let run = Run(
            id: "run-1",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .completed,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        try await handler.cancel(runID: "run-1")

        // Status should remain completed.
        let updated = try await store.getRun(id: "run-1")
        #expect(updated?.status == .completed)
    }

    @Test("Cancel throws for non-existent run")
    func cancelNonExistentRunThrows() async throws {
        let store = FakeWorkflowStore()
        let (handler, _, _) = makeHandler(store: store)

        await #expect(throws: EngineError.self) {
            try await handler.cancel(runID: "nonexistent")
        }
    }

    @Test("Cancel destroys tmux sessions for running/awaiting nodes")
    func cancelDestroysTmuxSessions() async throws {
        let store = FakeWorkflowStore()
        let tmux = FakeTmuxProvider()
        let (handler, _, _) = makeHandler(store: store, tmux: tmux)

        let run = Run(
            id: "run-tmux",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        // Create node executions: one running with a tmux session, one awaiting with a
        // tmux session, one completed (should not be destroyed).
        let runningWithTmux = NodeExecution(
            id: "exec-1", runID: "run-tmux", nodeID: "A",
            status: .running, tmuxSession: "orc-run-tmux-A"
        )
        let awaitingWithTmux = NodeExecution(
            id: "exec-2", runID: "run-tmux", nodeID: "B",
            status: .awaitingInput, tmuxSession: "orc-run-tmux-B"
        )
        let completedWithTmux = NodeExecution(
            id: "exec-3", runID: "run-tmux", nodeID: "C",
            status: .completed, tmuxSession: "orc-run-tmux-C"
        )
        let runningNoTmux = NodeExecution(
            id: "exec-4", runID: "run-tmux", nodeID: "D",
            status: .running
        )

        _ = try await store.createNodeExecution(runningWithTmux)
        _ = try await store.createNodeExecution(awaitingWithTmux)
        _ = try await store.createNodeExecution(completedWithTmux)
        _ = try await store.createNodeExecution(runningNoTmux)

        try await handler.cancel(runID: "run-tmux")

        // Only the running and awaiting nodes with tmux sessions should be destroyed.
        #expect(tmux.destroyedSessions.count == 2)
        #expect(tmux.destroyedSessions.contains("orc-run-tmux-A"))
        #expect(tmux.destroyedSessions.contains("orc-run-tmux-B"))
        // The completed node's tmux session should NOT have been destroyed.
        #expect(!tmux.destroyedSessions.contains("orc-run-tmux-C"))
    }
}
