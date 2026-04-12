import Testing
import Foundation
import Models
import Providers
@testable import Template
@testable import Engine

/// Tests for NodeDispatcher streaming event propagation — verifies that
/// workflow events (nodeStarted, nodeCompleted, nodeFailed, nodeSkipped)
/// are emitted correctly through the onEvent closure during execution.
@Suite("NodeDispatcher Streaming Events")
struct NodeDispatcherStreamingTests {

    // MARK: - Helpers

    /// Thread-safe event collector for capturing WorkflowEvents in tests.
    actor EventCollector {
        var events: [WorkflowEvent] = []
        func add(_ event: WorkflowEvent) { events.append(event) }
    }

    /// Creates a dispatcher configured with given workflow nodes and an event collector.
    private func makeDispatcher(
        nodes: [Models.Node],
        fakeProvider: FakeAgentProvider = FakeAgentProvider(name: "fake"),
        store: FakeWorkflowStore = FakeWorkflowStore(),
        onEvent: @escaping @Sendable (WorkflowEvent) -> Void = { _ in }
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
            tmux: FakeTmuxProvider(),
            onEvent: onEvent
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
            parser: FakeWorkflowParser(),
            templateResolver: TemplateResolver(),
            expressionEvaluator: ExpressionEvaluator(),
            evaluatorRunner: evaluatorRunner,
            interactiveHandler: interactiveHandler,
            loopHandler: loopHandler,
            maxParallelNodes: 4,
            repoRoot: "/tmp/repo",
            environment: [:],
            onEvent: onEvent
        )

        return (dispatcher, store, run)
    }

    // MARK: - nodeStarted + nodeCompleted

    @Test("Single node emits nodeStarted and nodeCompleted events")
    func singleNodeEvents() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "test output"

        let collector = EventCollector()

        let (dispatcher, store, run) = try makeDispatcher(
            nodes: [Models.Node(id: "step1", agent: .literal("fake"), prompt: "do thing")],
            fakeProvider: fakeProvider,
            onEvent: { event in
                Task { await collector.add(event) }
            }
        )

        _ = try await store.createRun(run)
        _ = try await dispatcher.execute(run: run, inputs: [:])

        // Allow async event collection to complete.
        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await collector.events
        let hasStarted = events.contains {
            if case .nodeStarted(let id, _, _) = $0, id == "step1" { return true }
            return false
        }
        let hasCompleted = events.contains {
            if case .nodeCompleted(let id, _, _) = $0, id == "step1" { return true }
            return false
        }

        #expect(hasStarted)
        #expect(hasCompleted)
    }

    // MARK: - nodeFailed

    @Test("Failed node emits nodeFailed event")
    func failedNodeEvent() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.errorToThrow = ProviderError.processFailure(
            command: "test", exitCode: 1, stderr: "error"
        )

        let collector = EventCollector()

        let (dispatcher, store, run) = try makeDispatcher(
            nodes: [Models.Node(id: "step1", agent: .literal("fake"), prompt: "fail")],
            fakeProvider: fakeProvider,
            onEvent: { event in
                Task { await collector.add(event) }
            }
        )

        _ = try await store.createRun(run)
        _ = try await dispatcher.execute(run: run, inputs: [:])

        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await collector.events
        let hasStarted = events.contains {
            if case .nodeStarted(let id, _, _) = $0, id == "step1" { return true }
            return false
        }
        let hasFailed = events.contains {
            if case .nodeFailed(let id, _, _) = $0, id == "step1" { return true }
            return false
        }

        #expect(hasStarted)
        #expect(hasFailed)
    }

    // MARK: - nodeSkipped (when: guard)

    @Test("Skipped node via when: guard emits nodeSkipped event")
    func skippedNodeEvent() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        let collector = EventCollector()

        // Use a when: expression that evaluates to false.
        // The expression "'false' == 'true'" always evaluates to false.
        let (dispatcher, store, run) = try makeDispatcher(
            nodes: [
                Models.Node(
                    id: "step1", agent: .literal("fake"), prompt: "skip me",
                    when: "'false' == 'true'"
                ),
            ],
            fakeProvider: fakeProvider,
            onEvent: { event in
                Task { await collector.add(event) }
            }
        )

        _ = try await store.createRun(run)
        _ = try await dispatcher.execute(run: run, inputs: [:])

        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await collector.events
        let hasSkipped = events.contains {
            if case .nodeSkipped(let id, _) = $0, id == "step1" { return true }
            return false
        }

        #expect(hasSkipped)
    }

    // MARK: - nodeOutput (streaming chunks)

    @Test("Streaming output emits nodeOutput events")
    func streamingOutputEvents() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.streamEvents = [
            .output("chunk1", .stdout),
            .output("chunk2", .stderr),
            .completed(TaskOutput(output: "final", exitStatus: 0)),
        ]

        let collector = EventCollector()

        let (dispatcher, store, run) = try makeDispatcher(
            nodes: [Models.Node(id: "step1", agent: .literal("fake"), prompt: "stream")],
            fakeProvider: fakeProvider,
            onEvent: { event in
                Task { await collector.add(event) }
            }
        )

        _ = try await store.createRun(run)
        _ = try await dispatcher.execute(run: run, inputs: [:])

        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await collector.events
        let outputChunks = events.compactMap { event -> (String, OutputStreamType)? in
            if case .nodeOutput(_, _, let chunk, let stream) = event { return (chunk, stream) }
            return nil
        }

        #expect(outputChunks.count == 2)
        #expect(outputChunks[0].0 == "chunk1")
        #expect(outputChunks[0].1 == .stdout)
        #expect(outputChunks[1].0 == "chunk2")
        #expect(outputChunks[1].1 == .stderr)
    }

    // MARK: - Skip cascading

    @Test("Cascaded skip emits nodeSkipped for downstream nodes")
    func cascadedSkipEvents() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "done"

        let collector = EventCollector()

        let nodes = [
            Models.Node(id: "A", agent: .literal("fake"), prompt: "do A"),
            // B is always skipped via when: guard
            Models.Node(
                id: "B", agent: .literal("fake"), prompt: "do B",
                dependsOn: ["A"], when: "'false' == 'true'"
            ),
            // C depends only on B — since B is skipped, C should also be skipped.
            Models.Node(id: "C", agent: .literal("fake"), prompt: "do C", dependsOn: ["B"]),
        ]

        let (dispatcher, store, run) = try makeDispatcher(
            nodes: nodes,
            fakeProvider: fakeProvider,
            onEvent: { event in
                Task { await collector.add(event) }
            }
        )

        _ = try await store.createRun(run)
        _ = try await dispatcher.execute(run: run, inputs: [:])

        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await collector.events
        let skippedIDs = events.compactMap { event -> String? in
            if case .nodeSkipped(let id, _) = event { return id }
            return nil
        }

        // Both B (when: guard) and C (cascade) should be skipped.
        #expect(skippedIDs.contains("B"))
        #expect(skippedIDs.contains("C"))
    }

    // MARK: - Event ordering

    @Test("Events follow correct order: started before completed")
    func eventOrdering() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "result"

        let collector = EventCollector()

        let (dispatcher, store, run) = try makeDispatcher(
            nodes: [Models.Node(id: "step1", agent: .literal("fake"), prompt: "go")],
            fakeProvider: fakeProvider,
            onEvent: { event in
                Task { await collector.add(event) }
            }
        )

        _ = try await store.createRun(run)
        _ = try await dispatcher.execute(run: run, inputs: [:])

        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await collector.events
        let startedIndex = events.firstIndex {
            if case .nodeStarted(let id, _, _) = $0, id == "step1" { return true }
            return false
        }
        let completedIndex = events.firstIndex {
            if case .nodeCompleted(let id, _, _) = $0, id == "step1" { return true }
            return false
        }

        // nodeStarted must come before nodeCompleted.
        if let si = startedIndex, let ci = completedIndex {
            #expect(si < ci)
        } else {
            Issue.record("Expected both nodeStarted and nodeCompleted events")
        }
    }
}
