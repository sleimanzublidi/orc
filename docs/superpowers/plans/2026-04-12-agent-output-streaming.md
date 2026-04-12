# Agent-Level Output Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream agent output and lifecycle events in real-time from the engine to CLI and web monitor consumers.

**Architecture:** Bottom-up: new event types in Models → streaming methods on ProcessRunner and providers → event propagation through NodeDispatcher/LoopHandler → WorkflowEngine.startStreaming() public API → CLI display and web monitor integration. Existing non-streaming paths remain unchanged.

**Tech Stack:** Swift 6.1, Foundation (Process, Pipe), AsyncThrowingStream, Swift Testing (@Test, #expect)

**Spec:** `docs/superpowers/specs/2026-04-12-agent-output-streaming-design.md`

---

### Task 1: Event types in Models

**Files:**
- Create: `Orc/Core/Models/Source/WorkflowEvent.swift`
- Create: `Orc/Core/Models/Source/ProcessStreamEvent.swift`
- Create: `Orc/Core/Models/Source/AgentStreamEvent.swift`
- Test: `Orc/Core/Models/Tests/WorkflowEventTests.swift`

- [ ] Create `WorkflowEvent` enum (runStarted, runCompleted, runFailed, nodeStarted, nodeOutput, nodeCompleted, nodeFailed, nodeSkipped) and `OutputStreamType` enum (.stdout, .stderr) in `WorkflowEvent.swift`
- [ ] Create `ProcessStreamEvent` enum (.stdout(Data), .stderr(Data), .completed(ProcessResult)) in `ProcessStreamEvent.swift`
- [ ] Create `AgentStreamEvent` enum (.output(String, OutputStreamType), .completed(TaskOutput)) in `AgentStreamEvent.swift`
- [ ] Write tests in `WorkflowEventTests.swift`: verify all event types are constructible and OutputStreamType raw values
- [ ] Run: `swift test --filter WorkflowEventTests` — all pass
- [ ] Commit

---

### Task 2: ProcessRunning protocol + ProcessRunner.runStreaming()

**Files:**
- Modify: `Orc/Core/Models/Source/Protocols.swift` — add `runStreaming()` to `ProcessRunning` with default implementation
- Modify: `Orc/Core/Providers/Source/ProcessRunner.swift` — implement `runStreaming()`
- Create: `Orc/Core/Providers/Tests/ProcessRunnerStreamingTests.swift`
- Modify: `Orc/Core/Engine/Tests/Fakes/FakeProcessRunner.swift` — add `runStreaming()` override
- Modify: `Orc/Core/Providers/Tests/Fakes/FakeProcessRunner.swift` — add `runStreaming()` override (if separate from Engine's)

Protocol addition in `Protocols.swift`:
```swift
// Add to ProcessRunning protocol
func runStreaming(
    command: String, arguments: [String], workingDirectory: String?,
    environment: [String: String]?, timeout: Int?,
    stdoutPath: String?, stderrPath: String?, executablePath: String?
) -> AsyncThrowingStream<ProcessStreamEvent, any Error>
```

Default implementation wraps `run()`:
```swift
extension ProcessRunning {
    public func runStreaming(
        command: String, arguments: [String], workingDirectory: String?,
        environment: [String: String]?, timeout: Int?,
        stdoutPath: String?, stderrPath: String?, executablePath: String? = nil
    ) -> AsyncThrowingStream<ProcessStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.run(
                        command: command, arguments: arguments,
                        workingDirectory: workingDirectory, environment: environment,
                        timeout: timeout, stdoutPath: stdoutPath,
                        stderrPath: stderrPath, executablePath: executablePath
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
```

**ProcessRunner implementation** uses `Pipe` + `Task.detached` blocking reads (cross-platform, avoids broken `readabilityHandler` on Linux):

1. Create Pipes for stdout/stderr, also create log files on disk
2. Set `process.standardOutput = stdoutPipe`, etc.
3. Set terminationHandler BEFORE `process.run()` (race avoidance)
4. After successful launch, spawn `Task.detached` readers that loop on `availableData`, writing to both log file AND yielding to continuation
5. On process exit: await readers to drain, close file handles
6. Check timeout flag, yield `.completed(ProcessResult)` or throw timeout error
7. `onTermination` cancels the outer task

Key detail: readers are spawned inside the `withCheckedThrowingContinuation` closure, after `process.run()` succeeds but before the continuation suspends. This ensures they start reading immediately while the process runs.

- [ ] Add `runStreaming()` to `ProcessRunning` protocol and default extension in `Protocols.swift`
- [ ] Write streaming tests in `ProcessRunnerStreamingTests.swift`: echo stdout, echo stderr, non-zero exit, timeout
- [ ] Run tests — they fail (default impl doesn't yield chunks)
- [ ] Implement `ProcessRunner.runStreaming()` with Pipe-based streaming
- [ ] Update both FakeProcessRunner files with a `runStreaming()` override (can use the default or a configurable handler)
- [ ] Run: `swift test --filter ProcessRunnerStreamingTests` — all pass
- [ ] Run: `swift test` — full suite passes (no regressions)
- [ ] Commit

---

### Task 3: AgentProviding protocol + Provider streaming implementations

**Files:**
- Modify: `Orc/Core/Models/Source/Protocols.swift` — add `executeStreaming()` to `AgentProviding`
- Modify: `Orc/Core/Providers/Source/ShellProvider.swift`
- Modify: `Orc/Core/Providers/Source/ClaudeCodeProvider.swift`
- Modify: `Orc/Core/Providers/Source/CLIAgentProvider.swift`
- Modify: `Orc/Core/Engine/Tests/Fakes/FakeAgentProvider.swift`
- Create: `Orc/Core/Providers/Tests/ShellProviderStreamingTests.swift`
- Create: `Orc/Core/Providers/Tests/ClaudeCodeProviderStreamingTests.swift`
- Create: `Orc/Core/Providers/Tests/CLIAgentProviderStreamingTests.swift`

Protocol addition:
```swift
func executeStreaming(
    prompt: String, context: TaskContext,
    timeout: Int?, parameters: [String: String]
) -> AsyncThrowingStream<AgentStreamEvent, any Error>
```

Default wraps `execute()`:
```swift
extension AgentProviding {
    public func executeStreaming(
        prompt: String, context: TaskContext,
        timeout: Int? = nil, parameters: [String: String] = [:]
    ) -> AsyncThrowingStream<AgentStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await self.execute(
                        prompt: prompt, context: context,
                        timeout: timeout, parameters: parameters
                    )
                    continuation.yield(.completed(output))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
```

**ShellProvider.executeStreaming():** Calls `processRunner.runStreaming()`. Maps `.stdout(Data)` → `.output(String, .stdout)`, `.stderr(Data)` → `.output(String, .stderr)`. On `.completed`, reads full stdout file via `FileReader.readContents(at:)`, checks exit code (throw on non-zero), yields `.completed(TaskOutput)`.

**ClaudeCodeProvider.executeStreaming():** Calls `processRunner.runStreaming()`. Streams `.stderr` chunks as `.output(String, .stderr)` (Claude Code progress). Ignores `.stdout` chunks (JSON fragments). On `.completed`, reads full stdout file, parses JSON via `parseClaudeJSON()`, checks exit code, yields `.completed(TaskOutput)`.

**CLIAgentProvider.executeStreaming():** Same pattern as ShellProvider — maps both stdout and stderr chunks, reads full output on completion.

**FakeAgentProvider:** Add `streamEvents: [AgentStreamEvent]?` property. If set, `executeStreaming()` yields those events. Otherwise falls back to default.

- [ ] Add `executeStreaming()` to `AgentProviding` protocol and default extension
- [ ] Write tests for each provider's streaming with mock ProcessRunner
- [ ] Implement `ShellProvider.executeStreaming()`
- [ ] Implement `ClaudeCodeProvider.executeStreaming()`
- [ ] Implement `CLIAgentProvider.executeStreaming()`
- [ ] Update `FakeAgentProvider` with configurable streaming
- [ ] Run: `swift test --filter ShellProviderStreamingTests && swift test --filter ClaudeCodeProviderStreamingTests && swift test --filter CLIAgentProviderStreamingTests` — all pass
- [ ] Run: `swift test` — full suite passes
- [ ] Commit

---

### Task 4: NodeDispatcher + LoopHandler event propagation

**Files:**
- Modify: `Orc/Core/Engine/Source/NodeDispatcher.swift` — add `onEvent` closure, use `executeStreaming` in `executeSingleNode`
- Modify: `Orc/Core/Engine/Source/LoopHandler.swift` — add `onEvent` closure, forward events during iterations
- Create: `Orc/Core/Engine/Tests/NodeDispatcherStreamingTests.swift`

**NodeDispatcher changes:**
- Add `let onEvent: @Sendable (WorkflowEvent) -> Void` property (defaulted to `{ _ in }` in init)
- In `executeSingleNode()`: call `onEvent(.nodeStarted(...))` before provider call. Replace `provider.execute()` with iteration over `provider.executeStreaming()`, forwarding `.output` chunks as `onEvent(.nodeOutput(...))`. On `.completed`, store output and call `onEvent(.nodeCompleted(...))`. On error, call `onEvent(.nodeFailed(...))`.
- In the batch loop where skipped nodes are handled: call `onEvent(.nodeSkipped(...))`
- Pass `onEvent` through to `LoopHandler` and `InteractiveHandler` constructors

**LoopHandler changes:**
- Add `let onEvent: @Sendable (WorkflowEvent) -> Void` property
- In `executeIterationWithRetry()`: forward `.output` chunks during each iteration

**Important:** The `onEvent` closure must be `@Sendable` because it's called from within `TaskGroup` tasks in the batch dispatcher.

- [ ] Write tests: single node emits nodeStarted+nodeCompleted, failed node emits nodeStarted+nodeFailed, skipped node emits nodeSkipped
- [ ] Add `onEvent` to NodeDispatcher init, emit events in `executeSingleNode`, handle skipped/failed
- [ ] Add `onEvent` to LoopHandler, forward iteration events
- [ ] Update NodeDispatcher construction sites in WorkflowEngine (start, resume) — pass `{ _ in }` for now
- [ ] Run: `swift test --filter NodeDispatcherStreamingTests` — pass
- [ ] Run: `swift test` — full suite passes (existing NodeDispatcherTests still pass with default onEvent)
- [ ] Commit

---

### Task 5: WorkflowEngine.startStreaming() + OrcEngineProviding

**Files:**
- Modify: `Orc/Core/Engine/Source/WorkflowEngine.swift` — add `startStreaming()` method
- Modify: `Orc/Core/Engine/Source/OrcEngineProviding.swift` — add `startStreaming()` to protocol
- Create: `Orc/Core/Engine/Tests/WorkflowEngineStreamingTests.swift`
- Modify: `Orc/CLI/Tests/MockEngine.swift` — add `startStreamingHandler`

**WorkflowEngine.startStreaming():**
```swift
public func startStreaming(
    workflowFile: String,
    inputs: [String: String],
    maxParallelNodes: Int? = nil
) async throws -> AsyncThrowingStream<WorkflowEvent, any Error>
```

Implementation:
1. Same setup as `start()`: parse, check concurrent runs, build plan, create run, create workspace, build handlers
2. Create `AsyncThrowingStream` with continuation
3. Yield `.runStarted(run)` immediately
4. Create `NodeDispatcher` with `onEvent` that yields to the continuation
5. Spawn a `Task` that runs `dispatcher.execute(run:inputs:)`, stores in `runningTasks`
6. On success: yield `.runCompleted(updatedRun)`, finish
7. On failure: yield `.runFailed(run, error:)`, finish with error
8. `continuation.onTermination` cancels the dispatch task
9. Return the stream

**OrcEngineProviding:** Add `startStreaming()` as a protocol requirement. Provide a default implementation that calls `start()` and wraps the result in a stream (for mocks that don't implement streaming).

**MockEngine:** Add `startStreamingHandler` closure property.

- [ ] Add `startStreaming()` to `OrcEngineProviding` with default implementation
- [ ] Update `MockEngine` with `startStreamingHandler`
- [ ] Write engine streaming tests: verify runStarted→node events→runCompleted sequence
- [ ] Implement `WorkflowEngine.startStreaming()`
- [ ] Run: `swift test --filter WorkflowEngineStreamingTests` — pass
- [ ] Run: `swift test` — full suite passes
- [ ] Commit

---

### Task 6: CLI StartCommand streaming display

**Files:**
- Modify: `Orc/CLI/Source/Commands/StartCommand.swift` — consume `startStreaming()`, display progress

**Changes to `execute(engine:)`:**
Replace the blocking `engine.start()` call with `engine.startStreaming()` consumption:

```swift
let eventStream = try await engine.startStreaming(
    workflowFile: resolvedFile, inputs: inputs, maxParallelNodes: maxParallelNodes
)

var completedRun: Run?
var nodeStartTimes: [String: Date] = [:]

for try await event in eventStream {
    switch event {
    case .runStarted:
        break  // Already printed "Running workflow..."
    case .nodeStarted(let nodeID, _, let agent):
        nodeStartTimes[nodeID] = Date()
        print("[\(nodeID)]    started (\(agent))")
    case .nodeOutput(let nodeID, _, let chunk, _):
        if verbose {
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[\(nodeID)]  | \(line)")
            }
        }
    case .nodeCompleted(let nodeID, _, _):
        let elapsed = nodeStartTimes[nodeID].map { Format.duration(Date().timeIntervalSince($0)) } ?? "?"
        print("[\(nodeID)]    completed (\(elapsed))")
    case .nodeFailed(let nodeID, _, let error):
        let elapsed = nodeStartTimes[nodeID].map { Format.duration(Date().timeIntervalSince($0)) } ?? "?"
        Format.printError("[\(nodeID)]    failed (\(elapsed)): \(error)")
    case .nodeSkipped(let nodeID, _):
        print("[\(nodeID)]    skipped")
    case .runCompleted(let run):
        completedRun = run
    case .runFailed(let run, _):
        completedRun = run
    }
}
```

Then use `completedRun` for the existing output/error display and completion hooks.

`--verbose` is already a flag on StartCommand — reuse it for showing output chunks.

- [ ] Modify `execute(engine:)` to use `startStreaming()` with progress display
- [ ] Verify existing StartCommandTests still compile (update mock handler if needed)
- [ ] Run: `swift test --filter StartCommandTests` — pass
- [ ] Run: `swift test` — full suite passes
- [ ] Commit

---

### Task 7: Web monitor StreamingEventSource

**Files:**
- Create: `Orc/Core/Server/Source/StreamingEventSource.swift`
- Create: `Orc/Core/Server/Tests/StreamingEventSourceTests.swift`

**StreamingEventSource** conforms to `EventProviding`. It wraps an `AsyncThrowingStream<WorkflowEvent, any Error>` and maps events to `MonitorEvent`:

- `.runStarted(run)` → `.runCreated(run)`
- `.runCompleted(run)` / `.runFailed(run, _)` → `.runUpdated(run)`
- `.nodeStarted` / `.nodeCompleted` / `.nodeFailed` / `.nodeSkipped` → `.nodeUpdated(NodeExecution)` (construct a lightweight NodeExecution from the event data)
- `.nodeOutput` → dropped (no SSE event type for this yet)

Note: This task does NOT wire StreamingEventSource into MonitorServer or StartCommand's `--monitor` path. That integration requires passing the stream through, which can be done in a follow-up. The class is implemented and tested in isolation.

- [ ] Write tests: feed WorkflowEvents, verify MonitorEvent mapping
- [ ] Implement `StreamingEventSource`
- [ ] Run: `swift test --filter StreamingEventSourceTests` — pass
- [ ] Run: `swift test` — full suite passes
- [ ] Commit

---

### Task 8: Final integration test + build verification

- [ ] Run full test suite: `swift test`
- [ ] Run build: `bash Scripts/build.sh`
- [ ] Run Docker build if available: `bash Scripts/build-linux.sh test`
- [ ] Fix any remaining issues
- [ ] Final commit with all fixes
