import Testing
import Foundation
import Models
import Providers
@testable import Template
@testable import Engine

/// Tests for workflow input default merging and caller validation of nested
/// workflow required inputs.
struct DefaultMergingTests {

    // MARK: - Helpers

    /// Creates a dispatcher configured with the given workflow and fake provider.
    private func makeDispatcher(
        workflow: Workflow,
        fakeProvider: FakeAgentProvider = FakeAgentProvider(name: "fake"),
        store: FakeWorkflowStore = FakeWorkflowStore(),
        parser: FakeWorkflowParser = FakeWorkflowParser()
    ) throws -> (NodeDispatcher, FakeWorkflowStore, Run) {
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
            workflowName: workflow.name,
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
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo"
        )

        return (dispatcher, store, run)
    }

    // MARK: - Default Merging

    @Test("Provided input is not overwritten by default value")
    func providedInputNotOverwrittenByDefault() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        // Workflow declares input "msg" with default "default-msg".
        let workflow = Workflow(
            name: "test",
            input: [
                WorkflowInput(name: "msg", defaultValue: "default-msg"),
            ],
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "say {{msg}}"),
            ]
        )
        let store = FakeWorkflowStore()
        let (dispatcher, _, run) = try makeDispatcher(
            workflow: workflow, fakeProvider: fakeProvider, store: store
        )
        _ = try await store.createRun(run)

        // Caller provides "msg" = "caller-msg" — it should NOT be overwritten.
        let result = try await dispatcher.execute(run: run, inputs: ["msg": "caller-msg"])
        #expect(result.status == .completed)
        #expect(fakeProvider.executedPrompts.contains("say caller-msg"))
    }

    @Test("Missing input with default value is filled from default")
    func missingInputFilledFromDefault() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        // Workflow declares input "msg" with default "hello-world".
        let workflow = Workflow(
            name: "test",
            input: [
                WorkflowInput(name: "msg", defaultValue: "hello-world"),
            ],
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "say {{msg}}"),
            ]
        )
        let store = FakeWorkflowStore()
        let (dispatcher, _, run) = try makeDispatcher(
            workflow: workflow, fakeProvider: fakeProvider, store: store
        )
        _ = try await store.createRun(run)

        // Caller does NOT provide "msg" — default should fill it.
        let result = try await dispatcher.execute(run: run, inputs: [:])
        #expect(result.status == .completed)
        #expect(fakeProvider.executedPrompts.contains("say hello-world"))
    }

    @Test("Missing required input with no default throws missingRequiredInput")
    func missingRequiredInputThrows() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        // Workflow declares required input "api_key" with no default.
        let workflow = Workflow(
            name: "test-workflow",
            input: [
                WorkflowInput(name: "api_key", required: true),
            ],
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "use {{api_key}}"),
            ]
        )
        let store = FakeWorkflowStore()
        let (dispatcher, _, run) = try makeDispatcher(
            workflow: workflow, fakeProvider: fakeProvider, store: store
        )
        _ = try await store.createRun(run)

        // Caller provides nothing — should throw missingRequiredInput.
        await #expect(throws: EngineError.self) {
            _ = try await dispatcher.execute(run: run, inputs: [:])
        }
    }

    // MARK: - Nested Workflow Caller Validation

    @Test("Nested workflow missing required input fails early")
    func nestedWorkflowMissingRequiredInputFails() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"
        let store = FakeWorkflowStore()

        // Child workflow requires "secret" with no default.
        let childWorkflow = Workflow(
            name: "child-wf",
            input: [
                WorkflowInput(name: "secret", required: true),
            ],
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "use {{secret}}"),
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["child.yml"] = childWorkflow

        // Parent node references child but does NOT pass "secret".
        let parentWorkflow = Workflow(
            name: "parent",
            nodes: [
                Models.Node(id: "nest", workflow: "child.yml", inputs: [:]),
            ]
        )
        let (dispatcher, _, run) = try makeDispatcher(
            workflow: parentWorkflow, fakeProvider: fakeProvider,
            store: store, parser: parser
        )
        _ = try await store.createRun(run)

        let result = try await dispatcher.execute(run: run, inputs: [:])

        // The parent run should fail because the child is missing a required input.
        #expect(result.status == .failed)

        // The child provider should NOT have been called.
        #expect(fakeProvider.executedPrompts.isEmpty)
    }

    @Test("Nested workflow with default fills missing input and succeeds")
    func nestedWorkflowDefaultFillsMissingInput() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "child-output"
        let store = FakeWorkflowStore()

        // Child workflow declares "greeting" with a default value.
        let childWorkflow = Workflow(
            name: "child-wf",
            input: [
                WorkflowInput(name: "greeting", required: true, defaultValue: "hello"),
            ],
            nodes: [
                Models.Node(id: "child-step", agent: .literal("fake"), prompt: "say {{greeting}}"),
            ]
        )
        var parser = FakeWorkflowParser()
        parser.workflowsByFile["child.yml"] = childWorkflow

        // Parent references child but does NOT pass "greeting". Since the child
        // has a default, the child's own default merging should fill it in.
        let parentWorkflow = Workflow(
            name: "parent",
            nodes: [
                Models.Node(id: "nest", workflow: "child.yml"),
            ]
        )
        let (dispatcher, _, run) = try makeDispatcher(
            workflow: parentWorkflow, fakeProvider: fakeProvider,
            store: store, parser: parser
        )
        _ = try await store.createRun(run)

        let result = try await dispatcher.execute(run: run, inputs: [:])

        // Should succeed — child default merging fills in "greeting" = "hello".
        #expect(result.status == .completed)
        #expect(fakeProvider.executedPrompts.contains("say hello"))
    }
}
