import Testing
import Foundation
import Models
import Providers
@testable import Template
@testable import Engine

/// Tests for NodeDispatcher — node execution, context propagation, when: guards,
/// failure strategies, skip cascading, and interactive/loop node dispatch.
struct NodeDispatcherTests {

    // MARK: - Helpers

    /// Creates a dispatcher configured with given workflow nodes and fake provider.
    private func makeDispatcher(
        nodes: [Models.Node],
        fakeProvider: FakeAgentProvider = FakeAgentProvider(name: "fake"),
        store: FakeWorkflowStore = FakeWorkflowStore(),
        parser: FakeWorkflowParser = FakeWorkflowParser(),
        maxParallelNodes: Int = 4
    ) throws -> (NodeDispatcher, FakeWorkflowStore, Run) {
        let workflow = Workflow(name: "test", nodes: nodes)
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)
        let registry = ProviderRegistry(providers: [fakeProvider])

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: TemplateResolver(),
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let interactiveHandler = InteractiveHandler(
            store: store,
            providers: registry,
            tmux: FakeTmuxProvider(),
            templateResolver: TemplateResolver()
        )

        let loopHandler = LoopHandler(
            providers: registry,
            store: store,
            evaluatorRunner: evaluatorRunner,
            templateResolver: TemplateResolver(),
            tmux: FakeTmuxProvider()
        )

        let run = Run(
            id: "test-run",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )

        let dispatcher = NodeDispatcher(
            plan: plan,
            providers: registry,
            store: store,
            parser: parser,
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: maxParallelNodes,
            repoRoot: "/tmp/repo"
        )

        return (dispatcher, store, run)
    }

    // MARK: - Basic Dispatch

    @Test("Single node executes and completes")
    func singleNodeExecution() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "result-A"
        let store = FakeWorkflowStore()

        let nodes = [Models.Node(id: "A", agent: .literal("fake"), prompt: "do A")]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        // Create the run in the store so updateRunStatus works.
        _ = try await store.createRun(run)

        let result = try await dispatcher.execute(run: run, inputs: [:])
        #expect(result.status == .completed)
    }

    @Test("Linear chain: A -> B, B receives A's output in context")
    func linearChainContextPropagation() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.outputs = ["do A": "output-from-A"]
        fakeProvider.defaultOutput = "output-from-B"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            Models.Node(id: "B", agent: .literal("fake"), prompt: "use {{A.output}}", dependsOn: ["A"]),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)

        // Verify that B received a prompt with A's output resolved.
        let executedPrompts = fakeProvider.executedPrompts
        #expect(executedPrompts.count == 2)
        #expect(executedPrompts[0] == "do A")
        #expect(executedPrompts[1] == "use output-from-A")
    }

    // MARK: - when: Guard

    @Test("Node is skipped when when: expression is false")
    func whenGuardSkipsNode() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            // when: expression references A.status which will be 'completed'
            // This expression will be false because 'completed' != 'failed'
            Models.Node(id: "B", agent: .literal("fake"), prompt: "do B", dependsOn: ["A"],
                        when: "{{A.status}} == 'failed'"),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)

        // Only A should have been executed.
        #expect(fakeProvider.executedPrompts.count == 1)
        #expect(fakeProvider.executedPrompts[0] == "do A")
    }

    @Test("Node runs when when: expression is true")
    func whenGuardRunsNode() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            Models.Node(id: "B", agent: .literal("fake"), prompt: "do B", dependsOn: ["A"],
                        when: "{{A.status}} == 'completed'"),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)
        #expect(fakeProvider.executedPrompts.count == 2)
    }

    // MARK: - Skip Cascading

    @Test("All deps skipped causes node to be skipped (cascade)")
    func skipCascading() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            // B is always skipped (when: false)
            Models.Node(id: "B", agent: .literal("fake"), prompt: "do B", dependsOn: ["A"],
                        when: "'false' == 'true'"),
            // C depends only on B — since B is skipped, C should be skipped too.
            Models.Node(id: "C", agent: .literal("fake"), prompt: "do C", dependsOn: ["B"]),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)
        // Only A should have executed.
        #expect(fakeProvider.executedPrompts.count == 1)
    }

    @Test("Mixed skipped + completed deps means node runs")
    func mixedSkippedAndCompleted() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            // B is always skipped
            Models.Node(id: "B", agent: .literal("fake"), prompt: "do B",
                        when: "'false' == 'true'"),
            // C depends on both A (completed) and B (skipped) — should still run.
            Models.Node(id: "C", agent: .literal("fake"), prompt: "do C", dependsOn: ["A", "B"]),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)
        // A and C should have executed.
        #expect(fakeProvider.executedPrompts.count == 2)
    }

    // MARK: - Failure Strategies

    @Test("on_failure: stop halts the entire run")
    func failureStop() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        let store = FakeWorkflowStore()

        // A will fail, B depends on A.
        fakeProvider.errorToThrow = ProviderError.processFailure(
            command: "fail", exitCode: 1, stderr: "error"
        )

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "fail", onFailure: .literal(.stop)),
            Models.Node(id: "B", agent: .literal("fake"), prompt: "do B", dependsOn: ["A"]),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .failed)
    }

    @Test("on_failure: continue allows downstream to run")
    func failureContinue() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        let store = FakeWorkflowStore()

        // A fails but has on_failure: continue.
        // We need to make only A fail.
        let failingProvider = FakeAgentProvider(name: "failing")
        failingProvider.errorToThrow = ProviderError.processFailure(
            command: "fail", exitCode: 1, stderr: "error"
        )

        let goodProvider = FakeAgentProvider(name: "good")
        goodProvider.defaultOutput = "success"

        let registry = ProviderRegistry(providers: [failingProvider, goodProvider])

        let nodes = [
            Models.Node(id: "A", agent: .literal("failing"), prompt: "fail", onFailure: .literal(.continue)),
            Models.Node(id: "B", agent: .literal("good"), prompt: "do B", dependsOn: ["A"]),
        ]

        let workflow = Workflow(name: "test", nodes: nodes)
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: TemplateResolver(),
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let interactiveHandler = InteractiveHandler(store: store, providers: registry, tmux: FakeTmuxProvider(), templateResolver: TemplateResolver())
        let loopHandler = LoopHandler(
            providers: registry, store: store,
            evaluatorRunner: evaluatorRunner, templateResolver: TemplateResolver(),
            tmux: FakeTmuxProvider()
        )

        let run = Run(
            id: "test-run", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .running, workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        let dispatcher = NodeDispatcher(
            plan: plan, providers: registry, store: store,
            parser: FakeWorkflowParser(),
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo"
        )

        let result = try await dispatcher.execute(run: run, inputs: [:])

        // Despite A failing, B should have run because A has on_failure: continue.
        #expect(result.status == .completed)
        #expect(goodProvider.executedPrompts.count == 1)
    }

    @Test("on_failure: skip causes downstream dependents to be skipped")
    func failureSkipCascadesToDependents() async throws {
        let store = FakeWorkflowStore()

        // A succeeds, B fails with on_failure: .skip, C depends only on B
        // so C should be skipped. The overall run should complete (not fail)
        // because .skip does not set runFailed.
        let goodProvider = FakeAgentProvider(name: "good")
        goodProvider.defaultOutput = "success"

        let failingProvider = FakeAgentProvider(name: "failing")
        failingProvider.errorToThrow = ProviderError.processFailure(
            command: "fail", exitCode: 1, stderr: "error"
        )

        let registry = ProviderRegistry(providers: [goodProvider, failingProvider])

        let nodes = [
            Models.Node(id: "A", agent: .literal("good"), prompt: "do A"),
            Models.Node(id: "B", agent: .literal("failing"), prompt: "fail B", dependsOn: ["A"], onFailure: .literal(.skip)),
            Models.Node(id: "C", agent: .literal("good"), prompt: "do C", dependsOn: ["B"]),
        ]

        let workflow = Workflow(name: "test", nodes: nodes)
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: TemplateResolver(),
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let interactiveHandler = InteractiveHandler(
            store: store, providers: registry,
            tmux: FakeTmuxProvider(), templateResolver: TemplateResolver()
        )

        let loopHandler = LoopHandler(
            providers: registry, store: store,
            evaluatorRunner: evaluatorRunner, templateResolver: TemplateResolver(),
            tmux: FakeTmuxProvider()
        )

        let run = Run(
            id: "test-run", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .running, workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        let dispatcher = NodeDispatcher(
            plan: plan, providers: registry, store: store,
            parser: FakeWorkflowParser(),
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo"
        )

        let result = try await dispatcher.execute(run: run, inputs: [:])

        // The run should complete (not fail) because .skip strategy does not
        // mark the run as failed -- it just skips downstream dependents.
        #expect(result.status == .completed)

        // A should have executed successfully.
        #expect(goodProvider.executedPrompts.count == 1)
        #expect(goodProvider.executedPrompts[0] == "do A")

        // C should NOT have been executed by the provider -- it was skipped
        // because B failed with .skip strategy and B is C's only dependency.
        // The skipDependents method removes C from pendingNodes and sets its
        // in-memory status to .skipped, so the good provider should not have
        // received C's prompt.
        #expect(!goodProvider.executedPrompts.contains("do C"))

        // B should have a failed execution record.
        let bExecs = try await store.getNodeExecutions(runID: run.id, nodeID: "B")
        #expect(bExecs.contains { $0.status == .failed })
    }

    // MARK: - Resume (Pre-completed Outputs)

    @Test("Dispatcher skips already-completed nodes during resume")
    func resumeSkipsCompleted() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "output-B"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            Models.Node(id: "B", agent: .literal("fake"), prompt: "do B", dependsOn: ["A"]),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)

        // Simulate that A was already completed in a previous run.
        let result = try await dispatcher.execute(
            run: run, inputs: [:],
            completedOutputs: ["A": "previous-output-A"]
        )

        #expect(result.status == .completed)
        // Only B should have been executed since A was already completed.
        #expect(fakeProvider.executedPrompts.count == 1)
    }

    // MARK: - Diamond DAG Dispatch

    @Test("Diamond DAG: A -> B,C -> D, all execute in correct order")
    func diamondDAGExecution() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "A"),
            Models.Node(id: "B", agent: .literal("fake"), prompt: "B", dependsOn: ["A"]),
            Models.Node(id: "C", agent: .literal("fake"), prompt: "C", dependsOn: ["A"]),
            Models.Node(id: "D", agent: .literal("fake"), prompt: "D", dependsOn: ["B", "C"]),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)
        // All 4 nodes should have executed.
        #expect(fakeProvider.executedPrompts.count == 4)
    }

    // MARK: - Nested Workflow Execution

    @Test("Nested workflow: child executes and output flows to parent")
    func nestedWorkflowBasicExecution() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "child-output"
        let store = FakeWorkflowStore()

        // Configure a child workflow that the parser returns for the nested file.
        let childWorkflow = Workflow(
            name: "child-workflow",
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "do child work")
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["child.yml"] = childWorkflow

        // Parent workflow has a single node that references the child workflow.
        let nodes = [
            Models.Node(id: "nest", output: "nest_result", workflow: "child.yml"),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store, parser: parser
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)
        // The child's agent should have been called.
        #expect(fakeProvider.executedPrompts.contains("do child work"))
    }

    @Test("Nested workflow with input mapping: parent passes resolved inputs to child")
    func nestedWorkflowInputMapping() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        // Parent node A produces output used as child input.
        fakeProvider.outputs = ["do A": "value-from-A"]
        fakeProvider.defaultOutput = "child-done"
        let store = FakeWorkflowStore()

        // Child workflow expects an input and uses it in a prompt.
        let childWorkflow = Workflow(
            name: "child-with-inputs",
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "process {{data}}")
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["child-inputs.yml"] = childWorkflow

        // Parent: A produces output, then nest-node passes A's output as "data" input.
        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A", output: "a_output"),
            Models.Node(
                id: "nest",
                dependsOn: ["A"],
                output: "nest_result",
                workflow: "child-inputs.yml",
                inputs: ["data": "{{a_output}}"]
            ),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store, parser: parser
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)

        // The child's prompt should have received the resolved input value.
        // The child uses "process {{data}}" and data = "value-from-A".
        #expect(fakeProvider.executedPrompts.contains("process value-from-A"))
    }

    @Test("Nested workflow failure: child fails causes parent node to fail")
    func nestedWorkflowFailure() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        // Make the child's agent fail.
        fakeProvider.errorToThrow = ProviderError.processFailure(
            command: "fail", exitCode: 1, stderr: "child error"
        )
        let store = FakeWorkflowStore()

        let childWorkflow = Workflow(
            name: "failing-child",
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "will fail")
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["failing-child.yml"] = childWorkflow

        let nodes = [
            Models.Node(id: "nest", onFailure: .literal(.stop), workflow: "failing-child.yml"),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store, parser: parser
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        // Parent run should fail because the child workflow failed.
        #expect(result.status == .failed)
    }

    @Test("Shared workspace: child uses same workspace path as parent")
    func nestedWorkflowSharedWorkspace() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "child-shared"
        let store = FakeWorkflowStore()

        let childWorkflow = Workflow(
            name: "shared-child",
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "shared work")
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["shared-child.yml"] = childWorkflow

        // workspaceMode defaults to .shared when nil.
        let nodes = [
            Models.Node(id: "nest", workflow: "shared-child.yml"),
        ]
        let (dispatcher, _, run) = try makeDispatcher(
            nodes: nodes, fakeProvider: fakeProvider, store: store, parser: parser
        )

        _ = try await store.createRun(run)
        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)

        // Verify the child run was created with the same workspace path as parent.
        let allRuns = try await store.listRuns(status: nil)
        // There should be 2 runs: parent and child.
        #expect(allRuns.count == 2)
        let childRun = allRuns.first { $0.workflowName == "shared-child" }
        #expect(childRun != nil)
        #expect(childRun?.workspacePath == run.workspacePath)
    }

    @Test("Isolated workspace: child gets sub-workspace under parent")
    func nestedWorkflowIsolatedWorkspace() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "child-isolated"
        let store = FakeWorkflowStore()

        let childWorkflow = Workflow(
            name: "isolated-child",
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "isolated work")
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["isolated-child.yml"] = childWorkflow

        // Use a temp directory as workspace so FileManager.createDirectory succeeds.
        let tmpWorkspace = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpWorkspace, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: tmpWorkspace) }

        let nodes = [
            Models.Node(
                id: "nest",
                workflow: "isolated-child.yml",
                workspaceMode: .literal(.isolated)
            ),
        ]

        // Build the dispatcher manually to use the temp workspace path.
        let workflow = Workflow(name: "test", nodes: nodes)
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)
        let registry = ProviderRegistry(providers: [fakeProvider])

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: TemplateResolver(),
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let interactiveHandler = InteractiveHandler(store: store, providers: registry, tmux: FakeTmuxProvider(), templateResolver: TemplateResolver())
        let loopHandler = LoopHandler(
            providers: registry, store: store,
            evaluatorRunner: evaluatorRunner, templateResolver: TemplateResolver(),
            tmux: FakeTmuxProvider()
        )

        let run = Run(
            id: "test-run-isolated",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: tmpWorkspace
        )
        _ = try await store.createRun(run)

        let dispatcher = NodeDispatcher(
            plan: plan, providers: registry, store: store,
            parser: parser,
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo"
        )

        let result = try await dispatcher.execute(run: run, inputs: [:])

        #expect(result.status == .completed)

        // Verify the child run was created with an isolated workspace path.
        let allRuns = try await store.listRuns(status: nil)
        let childRun = allRuns.first { $0.workflowName == "isolated-child" }
        #expect(childRun != nil)

        // The child workspace should be under <parent-workspace>/nested/<node-id>/
        let expectedPath = (tmpWorkspace as NSString)
            .appendingPathComponent("nested")
            .appending("/nest")
        #expect(childRun?.workspacePath == expectedPath)

        // Verify the directory was actually created.
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }

    // MARK: - Interactive Session tmuxSession Persistence

    @Test("Interactive session node persists tmuxSession in NodeExecution record")
    func interactiveSessionPersistsTmuxSession() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "session-output"
        let store = FakeWorkflowStore()

        // Configure tmux to exit immediately so the test doesn't wait.
        let tmux = FakeTmuxProvider()
        tmux.existsCheckCount = 0
        tmux.capturedOutput = "captured"

        let nodes = [
            Models.Node(
                id: "interactive-A",
                agent: .literal("fake"),
                prompt: "start session",
                interactive: .session
            ),
        ]

        let workflow = Workflow(name: "test", nodes: nodes)
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)
        let registry = ProviderRegistry(providers: [fakeProvider])

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: TemplateResolver(),
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let interactiveHandler = InteractiveHandler(
            store: store, providers: registry,
            tmux: tmux, templateResolver: TemplateResolver()
        )

        let loopHandler = LoopHandler(
            providers: registry, store: store,
            evaluatorRunner: evaluatorRunner, templateResolver: TemplateResolver(),
            tmux: tmux
        )

        let run = Run(
            id: "run-session",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        let dispatcher = NodeDispatcher(
            plan: plan, providers: registry, store: store,
            parser: FakeWorkflowParser(),
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo"
        )

        let result = try await dispatcher.execute(run: run, inputs: [:])
        #expect(result.status == .completed)

        // Verify the NodeExecution record has tmuxSession set to the expected
        // session name. This is critical for CancellationHandler to be able to
        // destroy the tmux session on cancel.
        let executions = try await store.getNodeExecutions(runID: run.id, nodeID: "interactive-A")
        #expect(executions.count == 1)
        #expect(executions[0].tmuxSession == "orc-run-session-interactive-A")
    }

    @Test("Interactive prompt node does not set tmuxSession")
    func interactivePromptDoesNotSetTmuxSession() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(
                id: "prompt-A",
                agent: .literal("fake"),
                prompt: "question",
                interactive: .prompt(message: "Please answer")
            ),
        ]

        let workflow = Workflow(name: "test", nodes: nodes)
        let planner = ExecutionPlanner()
        let plan = try planner.plan(workflow: workflow)
        let registry = ProviderRegistry(providers: [fakeProvider])

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: TemplateResolver(),
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let interactiveHandler = InteractiveHandler(
            store: store, providers: registry,
            tmux: FakeTmuxProvider(), templateResolver: TemplateResolver()
        )

        let loopHandler = LoopHandler(
            providers: registry, store: store,
            evaluatorRunner: evaluatorRunner, templateResolver: TemplateResolver(),
            tmux: FakeTmuxProvider()
        )

        let run = Run(
            id: "run-prompt",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
        _ = try await store.createRun(run)

        let dispatcher = NodeDispatcher(
            plan: plan, providers: registry, store: store,
            parser: FakeWorkflowParser(),
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo"
        )

        let result = try await dispatcher.execute(run: run, inputs: [:])

        // Prompt mode pauses the run, waiting for input.
        #expect(result.status == .awaitingInput)

        // Verify the NodeExecution record does NOT have tmuxSession set
        // because prompt mode doesn't use tmux.
        let executions = try await store.getNodeExecutions(runID: run.id, nodeID: "prompt-A")
        #expect(executions.count == 1)
        #expect(executions[0].tmuxSession == nil)
    }
}
