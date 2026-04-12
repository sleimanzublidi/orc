import Foundation
import Models
import Testing

@testable import Engine

/// Tests for ResumeHandler, which validates and prepares failed/cancelled/awaiting-input
/// runs for resumption by checking state, workspace existence, and node consistency.
struct ResumeHandlerTests {

    // MARK: - Helpers

    /// Creates a temporary directory that exists on disk, for workspace validation.
    private func makeTempWorkspace() -> String {
        let path = NSTemporaryDirectory() + "orc-resume-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Builds a Run with the given status and workspace path.
    private func makeRun(
        id: String = "run-1",
        status: RunStatus,
        workspacePath: String,
        workflowFile: String = "/tmp/workflow.yml"
    ) -> Run {
        Run(
            id: id,
            workflowName: "test-workflow",
            workflowFile: workflowFile,
            status: status,
            workspacePath: workspacePath
        )
    }

    /// Builds a completed NodeExecution for a given node ID.
    private func makeCompletedExecution(
        runID: String = "run-1",
        nodeID: String,
        output: String? = nil
    ) -> NodeExecution {
        NodeExecution(
            id: "exec-\(nodeID)",
            runID: runID,
            nodeID: nodeID,
            status: .completed,
            output: output
        )
    }

    // MARK: - Resume a failed run

    @Test("Resume a failed run returns run, workflow, and completed outputs")
    func resumeFailedRun() async throws {
        let workspace = makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let store = FakeWorkflowStore()
        let run = makeRun(status: .failed, workspacePath: workspace)
        _ = try await store.createRun(run)

        // Add a completed node execution with output.
        let exec = makeCompletedExecution(nodeID: "step1", output: "step1 result")
        _ = try await store.createNodeExecution(exec)

        let workflow = Workflow(
            name: "test-workflow",
            nodes: [
                Node(id: "step1", agent: .literal("fake"), prompt: "do something"),
                Node(id: "step2", agent: .literal("fake"), prompt: "do more", dependsOn: ["step1"]),
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        let handler = ResumeHandler(store: store, parser: parser)
        let (resumedRun, resumedWorkflow, completedOutputs) = try await handler.prepareResume(runID: "run-1")

        #expect(resumedRun.id == "run-1")
        #expect(resumedRun.status == .failed)
        #expect(resumedWorkflow.name == "test-workflow")
        #expect(resumedWorkflow.nodes.count == 2)
        #expect(completedOutputs["step1"] == "step1 result")
        #expect(completedOutputs["step2"] == nil)
    }

    // MARK: - Resume a cancelled run

    @Test("Resume a cancelled run returns run, workflow, and completed outputs")
    func resumeCancelledRun() async throws {
        let workspace = makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let store = FakeWorkflowStore()
        let run = makeRun(status: .cancelled, workspacePath: workspace)
        _ = try await store.createRun(run)

        // Two completed nodes, one with output and one without.
        _ = try await store.createNodeExecution(
            makeCompletedExecution(nodeID: "step1", output: "output A")
        )
        _ = try await store.createNodeExecution(
            makeCompletedExecution(nodeID: "step2", output: nil)
        )

        let workflow = Workflow(
            name: "test-workflow",
            nodes: [
                Node(id: "step1", agent: .literal("fake"), prompt: "first"),
                Node(id: "step2", agent: .literal("fake"), prompt: "second"),
                Node(id: "step3", agent: .literal("fake"), prompt: "third"),
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        let handler = ResumeHandler(store: store, parser: parser)
        let (resumedRun, resumedWorkflow, completedOutputs) = try await handler.prepareResume(runID: "run-1")

        #expect(resumedRun.status == .cancelled)
        #expect(resumedWorkflow.nodes.count == 3)
        // step1 had output, step2 did not (nil output is not stored).
        #expect(completedOutputs["step1"] == "output A")
        #expect(completedOutputs["step2"] == nil)
    }

    // MARK: - Resume an awaitingInput run

    @Test("Resume an awaitingInput run returns run, workflow, and completed outputs")
    func resumeAwaitingInputRun() async throws {
        let workspace = makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let store = FakeWorkflowStore()
        let run = makeRun(status: .awaitingInput, workspacePath: workspace)
        _ = try await store.createRun(run)

        _ = try await store.createNodeExecution(
            makeCompletedExecution(nodeID: "step1", output: "done")
        )

        let workflow = Workflow(
            name: "test-workflow",
            nodes: [
                Node(id: "step1", agent: .literal("fake"), prompt: "first"),
                Node(id: "step2", agent: .literal("fake"), prompt: "second"),
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        let handler = ResumeHandler(store: store, parser: parser)
        let (resumedRun, _, completedOutputs) = try await handler.prepareResume(runID: "run-1")

        #expect(resumedRun.status == .awaitingInput)
        #expect(completedOutputs["step1"] == "done")
    }

    // MARK: - Resume a completed run throws runNotResumable

    @Test("Resume a completed run throws runNotResumable")
    func resumeCompletedRunThrows() async throws {
        let workspace = makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let store = FakeWorkflowStore()
        let run = makeRun(status: .completed, workspacePath: workspace)
        _ = try await store.createRun(run)

        let parser = FakeWorkflowParser()
        let handler = ResumeHandler(store: store, parser: parser)

        await #expect(throws: EngineError.self) {
            _ = try await handler.prepareResume(runID: "run-1")
        }
    }

    // MARK: - Resume a nonexistent run throws runNotFound

    @Test("Resume a nonexistent run throws runNotFound")
    func resumeNonexistentRunThrows() async throws {
        let store = FakeWorkflowStore()
        let parser = FakeWorkflowParser()
        let handler = ResumeHandler(store: store, parser: parser)

        await #expect(throws: EngineError.self) {
            _ = try await handler.prepareResume(runID: "does-not-exist")
        }
    }

    // MARK: - Resume when workspace doesn't exist throws workspaceNotFound

    @Test("Resume when workspace doesn't exist throws workspaceNotFound")
    func resumeWithMissingWorkspaceThrows() async throws {
        let nonexistentPath = "/tmp/orc-resume-test-nonexistent-\(UUID().uuidString)"

        let store = FakeWorkflowStore()
        let run = makeRun(status: .failed, workspacePath: nonexistentPath)
        _ = try await store.createRun(run)

        let parser = FakeWorkflowParser()
        let handler = ResumeHandler(store: store, parser: parser)

        await #expect(throws: EngineError.self) {
            _ = try await handler.prepareResume(runID: "run-1")
        }
    }

    // MARK: - Resume when a completed node was removed throws completedNodeRemoved

    @Test("Resume when a previously completed node was removed from the workflow throws completedNodeRemoved")
    func resumeWithRemovedNodeThrows() async throws {
        let workspace = makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        let store = FakeWorkflowStore()
        let run = makeRun(status: .failed, workspacePath: workspace)
        _ = try await store.createRun(run)

        // step1 was completed in the previous run.
        _ = try await store.createNodeExecution(
            makeCompletedExecution(nodeID: "step1", output: "done")
        )

        // But the updated workflow no longer contains step1.
        let workflow = Workflow(
            name: "test-workflow",
            nodes: [
                Node(id: "step2", agent: .literal("fake"), prompt: "only step now"),
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        let handler = ResumeHandler(store: store, parser: parser)

        await #expect(throws: EngineError.self) {
            _ = try await handler.prepareResume(runID: "run-1")
        }
    }
}
