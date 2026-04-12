import Testing
import Foundation
import Models
import Providers
@testable import Template
@testable import Engine

/// Tests for LoopHandler — sequential iteration, evaluator integration, and max_iterations.
struct LoopHandlerTests {

    // MARK: - Helpers

    private func makeHandler(
        fakeProvider: FakeAgentProvider = FakeAgentProvider(name: "fake"),
        store: FakeWorkflowStore = FakeWorkflowStore()
    ) -> (LoopHandler, FakeWorkflowStore) {
        let registry = ProviderRegistry(providers: [fakeProvider])
        let resolver = TemplateResolver()

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: resolver,
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let handler = LoopHandler(
            providers: registry,
            store: store,
            evaluatorRunner: evaluatorRunner,
            templateResolver: resolver,
            tmux: FakeTmuxProvider()
        )

        return (handler, store)
    }

    private func makeRun() -> Run {
        Run(
            id: "test-run",
            workflowName: "test",
            workflowFile: "/tmp/test.yml",
            status: .running,
            workspacePath: "/tmp/workspace"
        )
    }

    // MARK: - Evaluator Stops Loop

    @Test("Loop stops when evaluator returns true")
    func loopStopsOnEvaluatorTrue() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        // On first call, return "no", on second return "yes".
        var callCount = 0
        fakeProvider.defaultOutput = "no"

        // We need a provider that changes output each call.
        // Use a different approach: the "approved" evaluator checks the lastOutput.
        // So make the provider return "yes" on the second call.

        let countingProvider = CountingFakeProvider(name: "fake", outputs: ["working", "yes"])
        let store = FakeWorkflowStore()
        let registry = ProviderRegistry(providers: [countingProvider])
        let resolver = TemplateResolver()

        let evaluatorRunner = EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: resolver,
            processRunner: FakeProcessRunner(),
            basePath: "/tmp/test-orc"
        )

        let handler = LoopHandler(
            providers: registry,
            store: store,
            evaluatorRunner: evaluatorRunner,
            templateResolver: resolver,
            tmux: FakeTmuxProvider()
        )

        let node = Models.Node(id: "loop-node", agent: .literal("fake"), prompt: "iterate")
        let loopConfig = ResolvedLoopConfig(until: "approved", maxIterations: 5, freshContext: false)
        let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/workspace")

        _ = try await store.createRun(makeRun())

        let output = try await handler.executeLoop(
            node: node, run: makeRun(), context: context,
            loopConfig: loopConfig,
            agentName: "fake",
            timeoutSeconds: nil,
            parameters: [:],
            retryConfig: nil
        )

        // Should have stopped after 2 iterations (second output was "yes").
        #expect(output.output == "yes")
        #expect(countingProvider.callCount == 2)
    }

    // MARK: - Max Iterations

    @Test("Loop throws maxIterationsReached when limit hit")
    func maxIterationsReached() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "not-approved"
        let store = FakeWorkflowStore()

        let (handler, _) = makeHandler(fakeProvider: fakeProvider, store: store)

        let node = Models.Node(id: "loop-node", agent: .literal("fake"), prompt: "iterate")
        let loopConfig = ResolvedLoopConfig(until: "approved", maxIterations: 3, freshContext: false)
        let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/workspace")

        _ = try await store.createRun(makeRun())

        await #expect(throws: EngineError.self) {
            try await handler.executeLoop(
                node: node, run: self.makeRun(), context: context,
                loopConfig: loopConfig,
                agentName: "fake",
                timeoutSeconds: nil,
                parameters: [:],
                retryConfig: nil
            )
        }
    }

    // MARK: - Evaluator Failure

    @Test("Evaluator that throws causes node failure, not infinite loop")
    func evaluatorFailureCausesNodeFailure() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "some output"
        let store = FakeWorkflowStore()

        let (handler, _) = makeHandler(fakeProvider: fakeProvider, store: store)

        let node = Models.Node(id: "loop-node", agent: .literal("fake"), prompt: "iterate")
        // Use a non-existent evaluator to trigger evaluatorNotFound.
        let loopConfig = ResolvedLoopConfig(until: "nonexistent_evaluator", maxIterations: 5, freshContext: false)
        let context = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp/workspace")

        _ = try await store.createRun(makeRun())

        await #expect(throws: EngineError.self) {
            try await handler.executeLoop(
                node: node, run: self.makeRun(), context: context,
                loopConfig: loopConfig,
                agentName: "fake",
                timeoutSeconds: nil,
                parameters: [:],
                retryConfig: nil
            )
        }

        // Should have only executed once — the evaluator failure on the first
        // iteration should terminate the loop.
        #expect(fakeProvider.executedPrompts.count == 1)
    }
}

// MARK: - CountingFakeProvider

/// A fake provider that returns different outputs on successive calls.
private final class CountingFakeProvider: AgentProviding, @unchecked Sendable {
    let name: String
    private let outputs: [String]
    private(set) var callCount = 0

    init(name: String, outputs: [String]) {
        self.name = name
        self.outputs = outputs
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil, parameters: [String: String] = [:]) async throws -> TaskOutput {
        let output = callCount < outputs.count ? outputs[callCount] : outputs.last ?? ""
        callCount += 1
        return TaskOutput(output: output, exitStatus: 0)
    }

    func executeInteractive(prompt: String, context: TaskContext, sessionName: String, timeout: Int? = nil) async throws -> TaskOutput {
        TaskOutput(output: "", exitStatus: 0)
    }
}
