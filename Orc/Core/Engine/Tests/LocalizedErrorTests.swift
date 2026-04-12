import Testing
import Foundation
import Models
import Providers
@testable import Parser
@testable import Store
@testable import Template
@testable import Engine

/// Tests that all error types conform to LocalizedError and produce structured
/// messages via localizedDescription (not opaque Foundation defaults).
struct LocalizedErrorTests {

    // MARK: - ParserError

    @Test("ParserError.localizedDescription returns structured message")
    func parserErrorLocalizedDescription() {
        let error: any Error = ParserError.yamlSyntax(detail: "unexpected token at line 5")
        #expect(error.localizedDescription == "YAML syntax error: unexpected token at line 5")
    }

    @Test("ParserError.localizedDescription matches description for all cases")
    func parserErrorAllCases() {
        let cases: [ParserError] = [
            .yamlSyntax(detail: "bad token"),
            .missingField(node: "build", field: "prompt"),
            .missingField(node: nil, field: "name"),
            .duplicateNodeID(id: "step-1"),
            .circularDependency(cycle: ["A", "B", "C"]),
            .invalidReference(node: "deploy", ref: "missing"),
            .invalidExpression(node: "check", detail: "unbalanced parens"),
            .invalidFieldType(node: "step-1", field: "timeout_seconds", expected: "integer or template string"),
        ]
        for parserError in cases {
            let anyError: any Error = parserError
            #expect(anyError.localizedDescription == parserError.description)
        }
    }

    // MARK: - StoreError

    @Test("StoreError.localizedDescription returns structured message")
    func storeErrorLocalizedDescription() {
        let error: any Error = StoreError.recordNotFound(table: "runs", id: "abc-123")
        #expect(error.localizedDescription == "Record 'abc-123' not found in 'runs'.")
    }

    @Test("StoreError.localizedDescription matches description for all cases")
    func storeErrorAllCases() {
        let cases: [StoreError] = [
            .databaseNotFound(path: "/tmp/orc.db"),
            .migrationFailed(version: 3, detail: "column already exists"),
            .recordNotFound(table: "node_executions", id: "xyz"),
            .writeFailure(detail: "disk full"),
            .internalError(detail: "unexpected nil"),
        ]
        for storeError in cases {
            let anyError: any Error = storeError
            #expect(anyError.localizedDescription == storeError.description)
        }
    }

    // MARK: - ProviderError

    @Test("ProviderError.localizedDescription returns structured message")
    func providerErrorLocalizedDescription() {
        let error: any Error = ProviderError.processFailure(
            command: "claude --prompt test", exitCode: 1, stderr: "API rate limit exceeded"
        )
        #expect(error.localizedDescription == "Process 'claude --prompt test' exited with code 1: API rate limit exceeded")
    }

    @Test("ProviderError.localizedDescription matches description for all cases")
    func providerErrorAllCases() {
        let cases: [ProviderError] = [
            .processFailure(command: "sh -c echo", exitCode: 127, stderr: "not found"),
            .timeout(command: "long-task", seconds: 300),
            .tmuxFailure(session: "orc-run-1", detail: "session not found"),
            .outputParseFailure(provider: "claude", detail: "empty response"),
            .providerNotFound(name: "gpt"),
        ]
        for providerError in cases {
            let anyError: any Error = providerError
            #expect(anyError.localizedDescription == providerError.description)
        }
    }

    // MARK: - EngineError

    @Test("EngineError.localizedDescription returns structured message")
    func engineErrorLocalizedDescription() {
        let error: any Error = EngineError.evaluatorFailed(name: "pass_fail", detail: "output was empty")
        #expect(error.localizedDescription == "Evaluator 'pass_fail' failed: output was empty")
    }

    @Test("EngineError.localizedDescription matches description for all cases")
    func engineErrorAllCases() {
        let cases: [EngineError] = [
            .workflowAlreadyRunning(id: "wf-1"),
            .runNotFound(id: "run-99"),
            .runNotResumable(id: "run-5", status: .completed),
            .workspaceNotFound(runID: "run-7"),
            .completedNodeRemoved(nodeID: "build"),
            .nodeNotAwaitingInput(nodeID: "step-2", status: .running),
            .evaluatorNotFound(name: "custom_eval"),
            .evaluatorFailed(name: "pass_fail", detail: "timeout"),
            .maxIterationsReached(nodeID: "refine", count: 10),
            .dependencyFailed(nodeID: "deploy", upstream: "test"),
            .cyclicDependency(nodes: ["A", "B"]),
            .nestedWorkflowFailed(nodeID: "sub", workflowFile: "child.yml", detail: "parse error"),
            .projectAlreadyExists(path: "/project/.orc"),
        ]
        for engineError in cases {
            let anyError: any Error = engineError
            #expect(anyError.localizedDescription == engineError.description)
        }
    }

    // MARK: - TemplateError

    @Test("TemplateError.localizedDescription returns structured message")
    func templateErrorLocalizedDescription() {
        let error: any Error = TemplateError.unresolvedVariable(name: "api_key")
        #expect(error.localizedDescription == "Unresolved variable '{{api_key}}'.")
    }

    @Test("TemplateError.localizedDescription matches description for all cases")
    func templateErrorAllCases() {
        let cases: [TemplateError] = [
            .unresolvedVariable(name: "user_input"),
            .malformedTemplate(detail: "unclosed {{"),
            .expressionSyntax(detail: "missing operand"),
            .expressionEvaluation(detail: "type mismatch"),
            .invalidConversion(value: "abc", targetType: "Int"),
        ]
        for templateError in cases {
            let anyError: any Error = templateError
            #expect(anyError.localizedDescription == templateError.description)
        }
    }

    // MARK: - Error Persistence

    @Test("Persisted error message contains structured detail, not opaque Foundation default")
    func persistedErrorMessageIsStructured() async throws {
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.errorToThrow = ProviderError.processFailure(
            command: "claude --prompt test", exitCode: 1, stderr: "API rate limit exceeded"
        )

        let store = FakeWorkflowStore()

        let nodes = [
            Models.Node(id: "failing-node", agent: .literal("fake"), prompt: "do something"),
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
        _ = try await store.createRun(run)

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
            repoRoot: "/tmp/repo"
        )

        let result = try await dispatcher.execute(run: run, inputs: [:])
        #expect(result.status == .failed)

        // Verify the persisted error message is the structured one, not the opaque Foundation default.
        let executions = try await store.getNodeExecutions(runID: "test-run", nodeID: "failing-node")
        let failedExec = executions.first { $0.status == .failed }
        #expect(failedExec != nil)

        // The error message should contain the structured ProviderError description.
        let errorMessage = failedExec?.error ?? ""
        #expect(errorMessage.contains("Process 'claude --prompt test' exited with code 1"))
        #expect(errorMessage.contains("API rate limit exceeded"))

        // It should NOT be the opaque Foundation default.
        #expect(!errorMessage.contains("The operation couldn't be completed"))
    }
}
