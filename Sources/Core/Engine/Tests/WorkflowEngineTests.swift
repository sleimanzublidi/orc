import Testing
import Foundation
import Models
import Providers
@testable import Template
@testable import Engine

/// Integration tests for WorkflowEngine — the main public API actor.
/// Uses the dependency-injection init with fakes for deterministic testing.
struct WorkflowEngineTests {

    // MARK: - Helpers

    private func makeEngine(
        store: FakeWorkflowStore = FakeWorkflowStore(),
        parser: FakeWorkflowParser = FakeWorkflowParser(),
        fakeProvider: FakeAgentProvider = FakeAgentProvider(name: "fake")
    ) -> (WorkflowEngine, FakeWorkflowStore) {
        let registry = ProviderRegistry(providers: [fakeProvider])
        let tmpDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let engine = WorkflowEngine(
            store: store,
            parser: parser,
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            providers: registry,
            workspaceManager: WorkspaceManager(basePath: tmpDir),
            configManager: ConfigManager(basePath: tmpDir)
        )

        return (engine, store)
    }

    // MARK: - Start

    @Test("Start parses workflow and completes run")
    func startCompletesRun() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        let workflow = Workflow(
            name: "test",
            nodes: [
                Models.Node(id: "A", agent: "fake", prompt: "do A")
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        let (engine, store) = makeEngine(
            parser: parser, fakeProvider: fakeProvider
        )

        let run = try await engine.start(
            workflowFile: "/tmp/test.yml",
            inputs: [:]
        )

        #expect(run.status == .completed)
        #expect(fakeProvider.executedPrompts.count == 1)
    }

    @Test("Start records stats after completion")
    func startRecordsStats() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        let workflow = Workflow(
            name: "stats-test",
            nodes: [
                Models.Node(id: "A", agent: "fake", prompt: "do A")
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)
        let store = FakeWorkflowStore()

        let (engine, _) = makeEngine(
            store: store, parser: parser, fakeProvider: fakeProvider
        )

        _ = try await engine.start(workflowFile: "/tmp/test.yml", inputs: [:])

        let stats = try await engine.getStats()
        #expect(stats.count == 1)
        #expect(stats[0].workflowName == "stats-test")
        #expect(stats[0].nodeCount == 1)
    }

    // MARK: - Query API

    @Test("listRuns returns stored runs")
    func listRuns() async throws {
        let store = FakeWorkflowStore()
        let (engine, _) = makeEngine(store: store)

        let run = Run(
            id: "run-1",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .completed,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        let runs = try await engine.listRuns()
        #expect(runs.count == 1)
        #expect(runs[0].id == "run-1")
    }

    @Test("listRuns filters by status")
    func listRunsFiltersByStatus() async throws {
        let store = FakeWorkflowStore()
        let (engine, _) = makeEngine(store: store)

        let run1 = Run(id: "run-1", workflowName: "test", workflowFile: "/tmp/test.yml",
                       status: .completed, workspacePath: "/tmp/workspace")
        let run2 = Run(id: "run-2", workflowName: "test", workflowFile: "/tmp/test.yml",
                       status: .failed, workspacePath: "/tmp/workspace")
        _ = try await store.createRun(run1)
        _ = try await store.createRun(run2)

        let completed = try await engine.listRuns(status: .completed)
        #expect(completed.count == 1)
        #expect(completed[0].id == "run-1")
    }

    @Test("getStatus returns run by ID")
    func getStatus() async throws {
        let store = FakeWorkflowStore()
        let (engine, _) = makeEngine(store: store)

        let run = Run(id: "run-1", workflowName: "test", workflowFile: "/tmp/test.yml",
                      status: .completed, workspacePath: "/tmp/workspace")
        _ = try await store.createRun(run)

        let result = try await engine.getStatus(runID: "run-1")
        #expect(result?.id == "run-1")
        #expect(result?.status == .completed)
    }

    @Test("getStatus returns nil for missing run")
    func getStatusMissing() async throws {
        let (engine, _) = makeEngine()
        let result = try await engine.getStatus(runID: "nonexistent")
        #expect(result == nil)
    }

    // MARK: - Cancel

    @Test("Cancel delegates to CancellationHandler")
    func cancelRun() async throws {
        let store = FakeWorkflowStore()
        let (engine, _) = makeEngine(store: store)

        let run = Run(id: "run-1", workflowName: "test", workflowFile: "/tmp/test.yml",
                      status: .running, workspacePath: "/tmp/workspace")
        _ = try await store.createRun(run)

        try await engine.cancel(runID: "run-1")

        let updated = try await store.getRun(id: "run-1")
        #expect(updated?.status == .cancelled)
    }

    // MARK: - Respond

    // MARK: - workflowAlreadyRunning Guard

    @Test("Start throws workflowAlreadyRunning when a run with the same file is in-flight")
    func startThrowsWorkflowAlreadyRunning() async throws {
        let store = FakeWorkflowStore()

        // Use an absolute path so canonicalization is a no-op.
        let workflowFile = "/tmp/already-running.yml"

        // Seed the store with an existing run that has status .running for the same file.
        let existingRun = Run(
            id: "existing-run",
            workflowName: "test",
            workflowFile: workflowFile,
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(existingRun)

        // Configure the parser to return a valid workflow for the same file.
        let workflow = Workflow(
            name: "test",
            nodes: [
                Models.Node(id: "A", agent: "fake", prompt: "do A")
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        let (engine, _) = makeEngine(
            store: store, parser: parser
        )

        // Attempting to start the same workflow file should throw workflowAlreadyRunning.
        await #expect(throws: EngineError.workflowAlreadyRunning(id: "existing-run")) {
            _ = try await engine.start(workflowFile: workflowFile, inputs: [:])
        }
    }

    // MARK: - Respond

    @Test("Respond completes node and resumes workflow so downstream nodes execute")
    func respondToNode() async throws {
        let store = FakeWorkflowStore()
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "downstream done"

        // Workflow: prompt-node (interactive) -> downstream (agent).
        // After respond() marks prompt-node complete, resume() should
        // re-dispatch and execute the downstream node.
        let workflow = Workflow(
            name: "test",
            nodes: [
                Models.Node(id: "prompt-node", agent: "fake",
                            interactive: .prompt(message: "approve?")),
                Models.Node(id: "downstream", agent: "fake", prompt: "do next",
                            dependsOn: ["prompt-node"]),
            ]
        )
        let parser = FakeWorkflowParser(workflow: workflow)

        // Create a workspace directory so ResumeHandler.prepareResume()
        // passes its workspace-exists check.
        let tmpDir = NSTemporaryDirectory() + "orc-respond-test-\(UUID().uuidString)"
        let workspacePath = tmpDir + "/workspaces/run-1"
        try FileManager.default.createDirectory(
            atPath: workspacePath, withIntermediateDirectories: true)

        let engine = WorkflowEngine(
            store: store,
            parser: parser,
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            providers: ProviderRegistry(providers: [fakeProvider]),
            workspaceManager: WorkspaceManager(basePath: tmpDir),
            configManager: ConfigManager(basePath: tmpDir)
        )

        let run = Run(id: "run-1", workflowName: "test", workflowFile: "/tmp/test.yml",
                      status: .awaitingInput, workspacePath: workspacePath)
        _ = try await store.createRun(run)

        // Create an awaiting_input node execution for the prompt node.
        let exec = NodeExecution(
            id: "exec-1", runID: "run-1", nodeID: "prompt-node",
            status: .awaitingInput, startedAt: Date()
        )
        _ = try await store.createNodeExecution(exec)

        try await engine.respond(runID: "run-1", nodeID: "prompt-node", response: "approved")

        // The prompt node should be marked completed with the response.
        let promptExecs = try await store.getNodeExecutions(runID: "run-1", nodeID: "prompt-node")
        #expect(promptExecs.last?.status == .completed)
        #expect(promptExecs.last?.output == "approved")

        // The run should have progressed past awaitingInput — resume()
        // re-dispatched and the downstream node executed.
        let updatedRun = try await store.getRun(id: "run-1")
        #expect(updatedRun?.status == .completed)

        // The downstream node should have been dispatched to the provider.
        let downstreamExecs = try await store.getNodeExecutions(runID: "run-1", nodeID: "downstream")
        #expect(downstreamExecs.contains { $0.status == .completed })
    }
}
