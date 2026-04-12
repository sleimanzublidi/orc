import Foundation
import Testing

@testable import Models

// MARK: - Codable Helpers

/// Encodes a value to JSON and decodes it back, returning the round-tripped result.
private func roundTrip<T: Codable & Sendable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try decoder.decode(T.self, from: data)
}

/// Decodes a JSON string into the given type.
private func decode<T: Codable>(_ json: String, as type: T.Type) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
}

/// Encodes a value to a JSON string.
private func encode<T: Codable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8)!
}

// MARK: - CleanupPolicy Tests

@Suite("CleanupPolicy Codable")
struct CleanupPolicyCodableTests {

    @Test("duration round-trips through 'Nd' format")
    func durationRoundTrip() throws {
        let policy = CleanupPolicy.duration(days: 30)
        let decoded = try roundTrip(policy)
        #expect(decoded == .duration(days: 30))
    }

    @Test("duration encodes as '30d'")
    func durationEncoding() throws {
        let json = try encode(CleanupPolicy.duration(days: 30))
        #expect(json == "\"30d\"")
    }

    @Test("duration decodes from '7d'")
    func durationDecoding() throws {
        let policy = try decode("\"7d\"", as: CleanupPolicy.self)
        #expect(policy == .duration(days: 7))
    }

    @Test("onSuccess round-trips through 'on_success'")
    func onSuccessRoundTrip() throws {
        let policy = CleanupPolicy.onSuccess
        let decoded = try roundTrip(policy)
        #expect(decoded == .onSuccess)
    }

    @Test("onSuccess encodes as 'on_success'")
    func onSuccessEncoding() throws {
        let json = try encode(CleanupPolicy.onSuccess)
        #expect(json == "\"on_success\"")
    }

    @Test("always round-trips")
    func alwaysRoundTrip() throws {
        let decoded = try roundTrip(CleanupPolicy.always)
        #expect(decoded == .always)
    }

    @Test("never round-trips")
    func neverRoundTrip() throws {
        let decoded = try roundTrip(CleanupPolicy.never)
        #expect(decoded == .never)
    }

    @Test("invalid value throws DecodingError")
    func invalidValueThrows() throws {
        #expect(throws: DecodingError.self) {
            try decode("\"bogus\"", as: CleanupPolicy.self)
        }
    }
}

// MARK: - InteractiveMode Tests

@Suite("InteractiveMode Codable")
struct InteractiveModeCodableTests {

    @Test("session round-trips as string 'session'")
    func sessionRoundTrip() throws {
        let mode = InteractiveMode.session
        let decoded = try roundTrip(mode)
        #expect(decoded == .session)
    }

    @Test("session encodes as plain string")
    func sessionEncoding() throws {
        let json = try encode(InteractiveMode.session)
        #expect(json == "\"session\"")
    }

    @Test("prompt round-trips as object")
    func promptRoundTrip() throws {
        let mode = InteractiveMode.prompt(message: "Enter value")
        let decoded = try roundTrip(mode)
        #expect(decoded == .prompt(message: "Enter value"))
    }

    @Test("prompt encodes as {\"prompt\":\"msg\"}")
    func promptEncoding() throws {
        let json = try encode(InteractiveMode.prompt(message: "hello"))
        #expect(json == "{\"prompt\":\"hello\"}")
    }

    @Test("prompt decodes from object")
    func promptDecoding() throws {
        let mode = try decode("{\"prompt\":\"test msg\"}", as: InteractiveMode.self)
        #expect(mode == .prompt(message: "test msg"))
    }

    @Test("invalid string throws")
    func invalidStringThrows() throws {
        #expect(throws: DecodingError.self) {
            try decode("\"invalid\"", as: InteractiveMode.self)
        }
    }
}

// MARK: - FailureStrategy Tests

@Suite("FailureStrategy")
struct FailureStrategyTests {

    @Test("all raw values round-trip", arguments: [
        FailureStrategy.stop,
        FailureStrategy.skip,
        FailureStrategy.continue,
    ])
    func rawValueRoundTrip(strategy: FailureStrategy) throws {
        let decoded = try roundTrip(strategy)
        #expect(decoded == strategy)
    }

    @Test("raw values are correct strings")
    func rawValues() {
        #expect(FailureStrategy.stop.rawValue == "stop")
        #expect(FailureStrategy.skip.rawValue == "skip")
        #expect(FailureStrategy.continue.rawValue == "continue")
    }
}

// MARK: - WorkspaceMode Tests

@Suite("WorkspaceMode")
struct WorkspaceModeTests {

    @Test("all raw values round-trip", arguments: [
        WorkspaceMode.shared,
        WorkspaceMode.isolated,
    ])
    func rawValueRoundTrip(mode: WorkspaceMode) throws {
        let decoded = try roundTrip(mode)
        #expect(decoded == mode)
    }

    @Test("raw values are correct strings")
    func rawValues() {
        #expect(WorkspaceMode.shared.rawValue == "shared")
        #expect(WorkspaceMode.isolated.rawValue == "isolated")
    }
}

// MARK: - RunStatus Tests

@Suite("RunStatus")
struct RunStatusTests {

    @Test("all raw values round-trip", arguments: [
        RunStatus.pending,
        RunStatus.running,
        RunStatus.awaitingInput,
        RunStatus.completed,
        RunStatus.failed,
        RunStatus.cancelled,
    ])
    func rawValueRoundTrip(status: RunStatus) throws {
        let decoded = try roundTrip(status)
        #expect(decoded == status)
    }

    @Test("awaitingInput raw value is 'awaiting_input'")
    func awaitingInputRawValue() {
        #expect(RunStatus.awaitingInput.rawValue == "awaiting_input")
    }
}

// MARK: - NodeStatus Tests

@Suite("NodeStatus")
struct NodeStatusTests {

    @Test("all raw values round-trip", arguments: [
        NodeStatus.pending,
        NodeStatus.running,
        NodeStatus.awaitingInput,
        NodeStatus.completed,
        NodeStatus.failed,
        NodeStatus.skipped,
        NodeStatus.cancelled,
    ])
    func rawValueRoundTrip(status: NodeStatus) throws {
        let decoded = try roundTrip(status)
        #expect(decoded == status)
    }

    @Test("awaitingInput raw value is 'awaiting_input'")
    func awaitingInputRawValue() {
        #expect(NodeStatus.awaitingInput.rawValue == "awaiting_input")
    }
}

// MARK: - EvaluatorType Tests

@Suite("EvaluatorType")
struct EvaluatorTypeTests {

    @Test("all raw values round-trip", arguments: [
        EvaluatorType.ai,
        EvaluatorType.script,
        EvaluatorType.workflow,
    ])
    func rawValueRoundTrip(type: EvaluatorType) throws {
        let decoded = try roundTrip(type)
        #expect(decoded == type)
    }
}

// MARK: - LogStream Tests

@Suite("LogStream")
struct LogStreamTests {

    @Test("all raw values round-trip", arguments: [
        LogStream.stdout,
        LogStream.stderr,
    ])
    func rawValueRoundTrip(stream: LogStream) throws {
        let decoded = try roundTrip(stream)
        #expect(decoded == stream)
    }
}

// MARK: - Workflow Tests

@Suite("Workflow")
struct WorkflowTests {

    @Test("round-trip encoding/decoding preserves all fields")
    func roundTripFull() throws {
        let workflow = Workflow(
            name: "deploy",
            description: "Deploy to production",
            input: [
                WorkflowInput(name: "env", type: "string", required: true),
                WorkflowInput(name: "dryRun", type: "bool", required: false),
            ],
            nodes: [
                Node(id: "build", agent: .literal("claude"), prompt: "Build the project"),
                Node(id: "test", command: "swift test", dependsOn: ["build"]),
            ],
            output: ["result": "{{build.output}}"],
            cleanupPolicy: .onSuccess
        )
        let decoded = try roundTrip(workflow)
        #expect(decoded == workflow)
    }

    @Test("default values are applied")
    func defaults() {
        let workflow = Workflow(name: "minimal")
        #expect(workflow.description == nil)
        #expect(workflow.input.isEmpty)
        #expect(workflow.nodes.isEmpty)
        #expect(workflow.output == nil)
        #expect(workflow.cleanupPolicy == .duration(days: 30))
    }

    @Test("equality check")
    func equality() {
        let a = Workflow(name: "test", description: "A")
        let b = Workflow(name: "test", description: "A")
        let c = Workflow(name: "test", description: "B")
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - WorkflowInput Tests

@Suite("WorkflowInput")
struct WorkflowInputTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let input = WorkflowInput(name: "branch", type: "string", required: true)
        let decoded = try roundTrip(input)
        #expect(decoded == input)
    }

    @Test("default values")
    func defaults() {
        let input = WorkflowInput(name: "x")
        #expect(input.type == "string")
        #expect(input.required == true)
    }
}

// MARK: - Node Tests

@Suite("Node")
struct NodeTests {

    @Test("round-trip with all fields populated")
    func fullRoundTrip() throws {
        let node = Node(
            id: "analyze",
            agent: .literal("claude"),
            prompt: "Analyze code",
            command: nil,
            dependsOn: ["build"],
            output: "analysis",
            when: "build.status == 'completed'",
            loop: LoopConfig(until: "tests_pass", maxIterations: .literal(5), freshContext: .literal(true)),
            interactive: .prompt(message: "Review?"),
            retry: RetryConfig(maxAttempts: .literal(3), delaySeconds: .literal(10)),
            timeoutSeconds: .literal(300),
            onFailure: .literal(.skip),
            workflow: nil,
            inputs: ["file": "main.swift"],
            workspaceMode: .literal(.isolated)
        )
        let decoded = try roundTrip(node)
        #expect(decoded == node)
    }

    @Test("minimal node round-trips")
    func minimalRoundTrip() throws {
        let node = Node(id: "step1")
        let decoded = try roundTrip(node)
        #expect(decoded == node)
    }

    @Test("default onFailure is .literal(.stop)")
    func defaultOnFailure() {
        let node = Node(id: "x")
        #expect(node.onFailure == .literal(.stop))
    }
}

// MARK: - LoopConfig Tests

@Suite("LoopConfig")
struct LoopConfigTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let config = LoopConfig(until: "done", maxIterations: .literal(20), freshContext: .literal(true))
        let decoded = try roundTrip(config)
        #expect(decoded == config)
    }

    @Test("default values")
    func defaults() {
        let config = LoopConfig(until: "condition")
        #expect(config.maxIterations == .literal(10))
        #expect(config.freshContext == .literal(false))
    }
}

// MARK: - RetryConfig Tests

@Suite("RetryConfig")
struct RetryConfigTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let config = RetryConfig(maxAttempts: .literal(5), delaySeconds: .literal(30))
        let decoded = try roundTrip(config)
        #expect(decoded == config)
    }

    @Test("default values")
    func defaults() {
        let config = RetryConfig()
        #expect(config.maxAttempts == .literal(1))
        #expect(config.delaySeconds == .literal(0))
    }
}

// MARK: - Run Tests

@Suite("Run")
struct RunTests {

    @Test("round-trip encoding/decoding preserves all fields")
    func fullRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let run = Run(
            id: "run-123",
            workflowName: "deploy",
            workflowFile: "deploy.yaml",
            status: .running,
            workspacePath: "/tmp/workspace",
            inputs: ["env": "prod"],
            output: "deployed",
            cleanupPolicy: .duration(days: 7),
            createdAt: now,
            updatedAt: now
        )
        let decoded = try roundTrip(run)
        #expect(decoded == run)
    }

    @Test("default values")
    func defaults() {
        let run = Run(
            id: "r1",
            workflowName: "test",
            workflowFile: "test.yaml",
            workspacePath: "/tmp"
        )
        #expect(run.status == .pending)
        #expect(run.inputs == nil)
        #expect(run.output == nil)
        #expect(run.cleanupPolicy == .duration(days: 30))
    }

    @Test("all RunStatus values in Run round-trip", arguments: [
        RunStatus.pending,
        RunStatus.running,
        RunStatus.awaitingInput,
        RunStatus.completed,
        RunStatus.failed,
        RunStatus.cancelled,
    ])
    func runWithEachStatus(status: RunStatus) throws {
        let run = Run(
            id: "r",
            workflowName: "w",
            workflowFile: "w.yaml",
            status: status,
            workspacePath: "/tmp",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            updatedAt: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try roundTrip(run)
        #expect(decoded.status == status)
    }
}

// MARK: - NodeExecution Tests

@Suite("NodeExecution")
struct NodeExecutionTests {

    @Test("round-trip encoding/decoding preserves all fields")
    func fullRoundTrip() throws {
        let started = Date(timeIntervalSince1970: 1700000000)
        let completed = Date(timeIntervalSince1970: 1700000060)
        let exec = NodeExecution(
            id: "exec-1",
            runID: "run-1",
            nodeID: "build",
            status: .completed,
            agent: "claude",
            attempt: 2,
            iteration: 3,
            prompt: "Build it",
            message: "interactive prompt",
            output: "success",
            error: nil,
            tmuxSession: "tmux-build",
            startedAt: started,
            completedAt: completed
        )
        let decoded = try roundTrip(exec)
        #expect(decoded == exec)
    }

    @Test("minimal node execution round-trips")
    func minimalRoundTrip() throws {
        let exec = NodeExecution(id: "e1", runID: "r1", nodeID: "n1")
        let decoded = try roundTrip(exec)
        #expect(decoded == exec)
    }

    @Test("default values")
    func defaults() {
        let exec = NodeExecution(id: "e", runID: "r", nodeID: "n")
        #expect(exec.status == .pending)
        #expect(exec.attempt == 1)
        #expect(exec.iteration == 1)
        #expect(exec.agent == nil)
        #expect(exec.prompt == nil)
        #expect(exec.message == nil)
        #expect(exec.output == nil)
        #expect(exec.error == nil)
        #expect(exec.tmuxSession == nil)
        #expect(exec.startedAt == nil)
        #expect(exec.completedAt == nil)
    }
}

// MARK: - EvaluatorDefinition Tests

@Suite("EvaluatorDefinition")
struct EvaluatorDefinitionTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let evaluator = EvaluatorDefinition(
            name: "check-tests",
            type: .script,
            agent: nil,
            prompt: nil,
            command: "swift test"
        )
        let decoded = try roundTrip(evaluator)
        #expect(decoded == evaluator)
    }

    @Test("AI evaluator with prompt round-trips")
    func aiEvaluator() throws {
        let evaluator = EvaluatorDefinition(
            name: "quality-gate",
            type: .ai,
            agent: "claude",
            prompt: "Is the code high quality?"
        )
        let decoded = try roundTrip(evaluator)
        #expect(decoded == evaluator)
    }
}

// MARK: - LogEntry Tests

@Suite("LogEntry")
struct LogEntryTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let entry = LogEntry(
            id: 42,
            nodeExecutionID: "exec-1",
            stream: .stdout,
            filePath: "/logs/out.log",
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
    }

    @Test("nil id round-trips")
    func nilIdRoundTrips() throws {
        let entry = LogEntry(
            nodeExecutionID: "exec-2",
            stream: .stderr,
            filePath: "/logs/err.log",
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try roundTrip(entry)
        #expect(decoded.id == nil)
        #expect(decoded.stream == .stderr)
    }
}

// MARK: - RunStats Tests

@Suite("RunStats")
struct RunStatsTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let stats = RunStats(
            id: 1,
            runID: "run-1",
            workflowName: "deploy",
            status: .completed,
            nodeCount: 5,
            durationSeconds: 120.5,
            completedAt: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try roundTrip(stats)
        #expect(decoded == stats)
    }

    @Test("nil optional fields round-trip")
    func nilOptionals() throws {
        let stats = RunStats(
            runID: "r1",
            workflowName: "test",
            status: .failed,
            nodeCount: 1,
            completedAt: Date(timeIntervalSince1970: 1700000000)
        )
        let decoded = try roundTrip(stats)
        #expect(decoded.id == nil)
        #expect(decoded.durationSeconds == nil)
    }
}

// MARK: - TaskContext Tests

@Suite("TaskContext")
struct TaskContextTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let ctx = TaskContext(
            inputs: ["branch": "main"],
            outputs: ["build": "ok"],
            nodeStatuses: ["build": .completed, "test": .pending],
            repoRoot: "/tmp/repo",

            workspacePath: "/workspace"
        )
        let decoded = try roundTrip(ctx)
        #expect(decoded == ctx)
    }

    @Test("default values")
    func defaults() {
        let ctx = TaskContext(repoRoot: "/tmp/repo", workspacePath: "/tmp")
        #expect(ctx.inputs.isEmpty)
        #expect(ctx.outputs.isEmpty)
        #expect(ctx.nodeStatuses.isEmpty)
    }
}

// MARK: - TaskOutput Tests

@Suite("TaskOutput")
struct TaskOutputTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let output = TaskOutput(output: "result", exitStatus: 0)
        let decoded = try roundTrip(output)
        #expect(decoded == output)
    }

    @Test("non-zero exit status")
    func nonZeroExit() throws {
        let output = TaskOutput(output: "error", exitStatus: 1)
        let decoded = try roundTrip(output)
        #expect(decoded.exitStatus == 1)
    }
}

// MARK: - ProcessResult Tests

@Suite("ProcessResult")
struct ProcessResultTests {

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let result = ProcessResult(
            exitCode: 0,
            stdoutPath: "/tmp/stdout",
            stderrPath: "/tmp/stderr"
        )
        let decoded = try roundTrip(result)
        #expect(decoded == result)
    }
}

// MARK: - ValidationResult Tests

@Suite("ValidationResult")
struct ValidationResultTests {

    @Test("isValid is true when no errors")
    func isValidNoErrors() {
        let result = ValidationResult(
            errors: [],
            warnings: [ValidationError(message: "warning")]
        )
        #expect(result.isValid == true)
    }

    @Test("isValid is false when errors exist")
    func isValidWithErrors() {
        let result = ValidationResult(
            errors: [ValidationError(message: "missing node", nodeID: "build")]
        )
        #expect(result.isValid == false)
    }

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let result = ValidationResult(
            errors: [ValidationError(message: "err", nodeID: "n1")],
            warnings: [ValidationError(message: "warn")]
        )
        let decoded = try roundTrip(result)
        #expect(decoded == result)
    }

    @Test("empty result is valid")
    func emptyIsValid() {
        let result = ValidationResult()
        #expect(result.isValid == true)
        #expect(result.errors.isEmpty)
        #expect(result.warnings.isEmpty)
    }
}

// MARK: - ValidationError Tests

@Suite("ValidationError")
struct ValidationErrorTests {

    @Test("equality")
    func equality() {
        let a = ValidationError(message: "error", nodeID: "n1")
        let b = ValidationError(message: "error", nodeID: "n1")
        let c = ValidationError(message: "different")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("round-trip encoding/decoding")
    func roundTrips() throws {
        let err = ValidationError(message: "cycle detected", nodeID: "node-a")
        let decoded = try roundTrip(err)
        #expect(decoded == err)
    }
}
