# Agent-Level Output Streaming — Design Spec

Real-time streaming of agent output during workflow execution. Enables consumers (CLI, web monitor) to observe node lifecycle events and output chunks as they happen, rather than waiting for the entire workflow to complete.

---

## 1. Event Types (Models)

New file: `Models/Source/WorkflowEvent.swift`

```swift
public enum WorkflowEvent: Sendable {
    case runStarted(Run)
    case runCompleted(Run)
    case runFailed(Run, error: String)
    case nodeStarted(nodeID: String, runID: String, agent: String)
    case nodeOutput(nodeID: String, runID: String, chunk: String, stream: OutputStreamType)
    case nodeCompleted(nodeID: String, runID: String, output: String?)
    case nodeFailed(nodeID: String, runID: String, error: String)
    case nodeSkipped(nodeID: String, runID: String)
}

public enum OutputStreamType: String, Sendable, Codable {
    case stdout
    case stderr
}
```

These live in the Models module so both Engine and Server can use them without circular dependencies.

---

## 2. Process-Level Streaming (Providers)

### ProcessStreamEvent

New file: `Models/Source/ProcessStreamEvent.swift`

```swift
public enum ProcessStreamEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case completed(ProcessResult)
}
```

### ProcessRunning Protocol Extension

Add to `Protocols.swift`:

```swift
public protocol ProcessRunning: Sendable {
    // ... existing run() method ...

    func runStreaming(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Int?,
        stdoutPath: String?,
        stderrPath: String?,
        executablePath: String?
    ) -> AsyncThrowingStream<ProcessStreamEvent, any Error>
}
```

Default implementation calls `run()` and wraps the result:

```swift
extension ProcessRunning {
    public func runStreaming(...) -> AsyncThrowingStream<ProcessStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let result = try await self.run(...)
                continuation.yield(.completed(result))
                continuation.finish()
            }
        }
    }
}
```

### ProcessRunner.runStreaming() Implementation

Uses `Pipe` for stdout/stderr with `Task.detached` blocking reads. This approach is cross-platform (works on both macOS and Linux — avoids `FileHandle.readabilityHandler` which is broken on Linux).

Flow:
1. Create `Pipe()` for stdout and stderr
2. Create log files on disk (same as current behavior for `logs` table)
3. Set `process.standardOutput = stdoutPipe`, `process.standardError = stderrPipe`
4. Launch process (terminationHandler set before `run()` to avoid race)
5. Spawn two `Task.detached` readers:
   - Each reads `pipe.fileHandleForReading.availableData` in a loop
   - Each write to both the log file AND yields to the continuation
   - Loop exits on empty data (EOF)
6. On process termination: await both readers, close file handles
7. Yield `.completed(ProcessResult)` with log file paths and exit code
8. Handle timeout via same `TimeoutFlag` pattern as existing `run()`
9. Handle cancellation via `onTermination` → SIGTERM

Two blocked threads per streaming process is acceptable given `maxParallelNodes` bounds concurrency.

---

## 3. Agent-Level Streaming (Providers)

### AgentStreamEvent

New file: `Models/Source/AgentStreamEvent.swift`

```swift
public enum AgentStreamEvent: Sendable {
    case output(String, OutputStreamType)
    case completed(TaskOutput)
}
```

### AgentProviding Protocol Extension

Add to `Protocols.swift`:

```swift
public protocol AgentProviding: Sendable {
    // ... existing methods ...

    func executeStreaming(
        prompt: String,
        context: TaskContext,
        timeout: Int?,
        parameters: [String: String]
    ) -> AsyncThrowingStream<AgentStreamEvent, any Error>
}
```

Default implementation calls `execute()` and wraps:

```swift
extension AgentProviding {
    public func executeStreaming(...) -> AsyncThrowingStream<AgentStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let output = try await self.execute(...)
                continuation.yield(.completed(output))
                continuation.finish()
            }
        }
    }
}
```

### Provider Implementations

**ShellProvider**: Calls `processRunner.runStreaming()`. Maps `.stdout(Data)` → `.output(String, .stdout)`, `.stderr(Data)` → `.output(String, .stderr)`. On `.completed`, reads full stdout file for `TaskOutput.output`, yields `.completed(TaskOutput)`.

**CLIAgentProvider**: Same pattern as ShellProvider — direct mapping of process events to agent events.

**ClaudeCodeProvider**: Calls `processRunner.runStreaming()`. Streams `.stderr` chunks as `.output(String, .stderr)` (Claude Code writes progress to stderr). Buffers `.stdout` silently (it's JSON). On `.completed`, parses the JSON stdout to extract the `result` field, yields `.completed(TaskOutput)`.

---

## 4. Engine Event Propagation

### NodeDispatcher

Add an `onEvent` closure parameter:

```swift
struct NodeDispatcher: Sendable {
    // ... existing properties ...
    let onEvent: @Sendable (WorkflowEvent) -> Void

    init(..., onEvent: @Sendable (WorkflowEvent) -> Void = { _ in }) { ... }
}
```

The non-streaming path (`start()`) passes the default no-op. The streaming path passes a closure that yields to the stream continuation.

**Event emission points in `execute()`:**

- Before dispatching a node: `onEvent(.nodeStarted(nodeID:runID:agent:))`
- `executeSingleNode()` — iterate `provider.executeStreaming()`, forwarding `.output` chunks as `onEvent(.nodeOutput(...))`. On `.completed`, persist to store and `onEvent(.nodeCompleted(...))`.
- On node failure: `onEvent(.nodeFailed(...))`
- On node skipped: `onEvent(.nodeSkipped(...))`

**Loop nodes**: `LoopHandler` also receives the `onEvent` closure. Each iteration's provider output chunks are forwarded.

**Interactive nodes**: Emit `nodeStarted`. When entering `awaitingInput`, no further output events until resumed.

### WorkflowEngine.startStreaming()

New public method:

```swift
public func startStreaming(
    workflowFile: String,
    inputs: [String: String],
    maxParallelNodes: Int? = nil
) -> AsyncThrowingStream<WorkflowEvent, any Error>
```

Implementation:
1. Creates `AsyncThrowingStream` with continuation
2. Spawns a `Task` that runs the same setup as `start()` (parse, plan, create run, create workspace, build handlers)
3. Yields `.runStarted(run)` immediately
4. Creates `NodeDispatcher` with `onEvent` closure that yields to the continuation
5. Awaits `dispatcher.execute(run:inputs:)`
6. On success: yields `.runCompleted(run)` then `continuation.finish()`
7. On failure: yields `.runFailed(run, error:)` then `continuation.finish(throwing:)`
8. Tracks the task in `runningTasks` for cancellation support
9. `continuation.onTermination` cancels the task

### OrcEngineProviding Protocol

Add:

```swift
func startStreaming(
    workflowFile: String,
    inputs: [String: String],
    maxParallelNodes: Int?
) async throws -> AsyncThrowingStream<WorkflowEvent, any Error>
```

Note: The method is `async throws` because the setup phase (parsing, run creation) happens before the stream is returned. The stream itself conveys execution events.

`WorkflowEngine` conforms via the new method. The existing `start()` method is unchanged.

---

## 5. CLI Display

### StartCommand Changes

When consuming `startStreaming()`, the default compact progress view prints lifecycle events:

```
Running workflow deploy.yml
[build]    started (shell)
[build]    completed (3.2s)
[test]     started (shell)
[deploy]   started (claude-code)
[test]     completed (12.1s)
[deploy]   completed (45.3s)
Workflow run a1b2c3d4 completed
Output: Deployed successfully
```

With `--verbose`, output chunks are also printed:

```
Running workflow deploy.yml
[build]    started (shell)
[build]  | Compiling main.swift...
[build]  | Build complete!
[build]    completed (3.2s)
...
```

Implementation:
- Consume the `AsyncThrowingStream<WorkflowEvent, Error>` in a `for try await` loop
- Track node start times in a local dictionary for elapsed time display
- Print lifecycle events to stdout
- When `--verbose`: also print `.nodeOutput` chunks, prefixed with `[nodeID]  | `
- After stream ends, print final run status and output (same as current behavior)
- Collect the final `Run` from the `.runCompleted` / `.runFailed` event

The existing non-streaming code path (calling `engine.start()`) is replaced by the streaming path. If the engine doesn't support streaming (mock in tests), the `OrcEngineProviding` protocol's default implementation can wrap `start()`.

---

## 6. Web Monitor Integration

### StreamingEventSource

New class in Server module, conforming to `EventProviding`:

```swift
final class StreamingEventSource: EventProviding, Sendable {
    private let eventStream: AsyncThrowingStream<WorkflowEvent, any Error>

    init(eventStream: AsyncThrowingStream<WorkflowEvent, any Error>) { ... }

    func events() -> AsyncStream<MonitorEvent> {
        // Maps WorkflowEvent → MonitorEvent
        // nodeStarted/nodeCompleted/nodeFailed → nodeUpdated (fetch full NodeExecution from store)
        // runStarted → runCreated
        // runCompleted/runFailed → runUpdated
        // nodeOutput → (dropped for now — SSE doesn't have this event type yet)
    }

    func shutdown() async { /* cancel iteration */ }
}
```

The existing `PollingEventSource` remains the default. `StreamingEventSource` is used when a streaming engine is available (e.g., when `orc start --monitor` starts the workflow and monitor together). This is opt-in — `orc monitor` (standalone) continues to poll because it monitors already-running workflows it didn't start.

**The `MonitorEvent` enum is unchanged.** The web monitor spec's future `node:output` SSE event type is deferred — it requires browser-side changes to display streaming output.

---

## 7. Testing Strategy

### ProcessRunner Streaming Tests (`ProcessRunnerTests.swift`)

- `runStreaming()` with `echo "hello"`: verify `.stdout(Data)` chunk received, followed by `.completed` with exit code 0 and valid stdout file path
- `runStreaming()` with a command that writes to stderr: verify `.stderr(Data)` chunks
- `runStreaming()` with non-zero exit: verify `.completed` carries the exit code
- `runStreaming()` with timeout: verify `ProviderError.timeout` is thrown
- Verify log files on disk contain the same content that was streamed

### Provider Streaming Tests

- `ShellProvider.executeStreaming()`: mock `ProcessRunning`, verify stdout chunks map to `.output(String, .stdout)`
- `ClaudeCodeProvider.executeStreaming()`: mock `ProcessRunning`, verify stderr chunks stream and stdout JSON is parsed on completion
- `CLIAgentProvider.executeStreaming()`: similar to shell

### NodeDispatcher Streaming Tests (`NodeDispatcherTests.swift`)

- Single node with `onEvent` closure: verify `nodeStarted`, `nodeOutput` (if verbose), `nodeCompleted` events emitted in order
- Failed node: verify `nodeStarted` then `nodeFailed`
- Skipped node (when: false): verify `nodeSkipped`
- Multi-node workflow: verify events from parallel nodes interleave correctly

### WorkflowEngine Streaming Tests (`WorkflowEngineTests.swift`)

- `startStreaming()` with mock store/providers: verify `runStarted` → node events → `runCompleted` sequence
- `startStreaming()` with failing node: verify `runFailed` event

### StreamingEventSource Tests (`EventSourceTests.swift`)

- Feed known `WorkflowEvent`s, verify correct `MonitorEvent` mapping

### FakeAgentProvider / FakeProcessRunner Updates

- `FakeAgentProvider` gains `executeStreaming()` that yields from a configurable `streamEvents` array
- `FakeProcessRunner` gains `runStreaming()` that yields from a configurable array

---

## 8. Out of Scope

- **Batch-sequential dispatch optimization**: The existing TODO (NodeDispatcher line 112) about processing TaskGroup results one-at-a-time is a separate optimization. This design adds event propagation within the existing batch model.
- **`resumeStreaming()`**: Streaming support for `resume()` can be added later with the same pattern.
- **`node:output` SSE events**: The web monitor doesn't emit output chunks over SSE yet. This requires browser-side changes (auto-scrolling log panel with live updates) that are out of scope.
- **Incremental DB persistence**: Output is stored as a complete string on node completion (current behavior). No schema changes.
- **ANSI terminal UI**: No in-place line updates, progress bars, or spinners. Plain sequential output for v1.
