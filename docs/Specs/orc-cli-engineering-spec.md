# Orc CLI — Engineering Spec

Engineering specification for the Orc CLI. Translates the [design spec](../orc-cli-design-spec.md) into buildable Swift modules with defined boundaries, types, dependencies, and test strategies.

---

## 1. Overview & Code Conventions

### Toolchain

- Swift 6.0, strict concurrency checking enabled
- macOS deployment target: macOS 14 (Sonoma)
- Swift Package Manager as the build system

### Third-Party Dependencies

| Package | Version | Used By | Purpose |
|---|---|---|---|
| [Yams](https://github.com/jpsim/Yams) | 5.x | Parser | YAML deserialization |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.x | Store | SQLite persistence, WAL mode, migrations |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.x | CLI | Command-line argument parsing |
| [swift-log](https://github.com/apple/swift-log) | 1.x | Engine, Providers | Structured logging |
| [swift-format](https://github.com/swiftlang/swift-format) | — | Dev tooling | Code formatting (not a package dependency) |

### Code Conventions

- **Strict concurrency:** all `public` types must be `Sendable`. Zero warnings.
- **Actors** for mutable shared state. Structured concurrency (`TaskGroup`, `async let`) for parallelism.
- **Protocol-first boundaries:** every layer crossing is a protocol. Concrete types are `internal`.
- **Protocol naming:** protocols end in `-ing` (capability name), implementations are the noun/verb. Example: `protocol AgentProviding` / `actor AgentProvider: AgentProviding`.
- **No force unwraps** outside of tests.
- **Per-module typed errors** (e.g., `ParserError`, `StoreError`).
- **Test colocation:** `<Component>/Source/`, `<Component>/Tests/`.
- **Swift Testing** framework (`@Test`, `#expect`).
- **swift-format** for formatting, configured at package root via `.swift-format`.
- Follow **Swift API Design Guidelines** for naming.
- **Access control:** `internal` by default, explicit `public` only on the Engine API surface.
- **Avoid free functions:** use `enum` with static functions instead.

---

## 2. Package Structure & Dependency Graph

### Directory Layout

Each module is a separate SPM target, enforcing protocol boundaries at compile time.

```
Orc/
├── Orc/
│   ├── Package.swift
│   ├── .swift-format
│   ├── Core/
│   │   ├── Models/
│   │   │   ├── Source/
│   │   │   └── Tests/
│   │   ├── Template/
│   │   │   ├── Source/
│   │   │   └── Tests/
│   │   ├── Parser/
│   │   │   ├── Source/
│   │   │   └── Tests/
│   │   ├── Store/
│   │   │   ├── Source/
│   │   │   └── Tests/
│   │   ├── Providers/
│   │   │   ├── Source/
│   │   │   └── Tests/
│   │   └── Engine/
│   │       ├── Source/
│   │       └── Tests/
│   └── CLI/
│       ├── Main/
│       │   └── CLI.swift       # @main entry point (executable)
│       ├── Source/
│       │   ├── Commands/       # Subcommand implementations
│       │   └── Util/           # Formatting, OrcDirectory
│       └── Tests/
├── Docs/
│   └── Specs/
└── CLAUDE.md
```

### Target Dependency Graph

Arrows = "depends on".

```
CLI (executable)
 ├── Engine
 │    ├── Providers
 │    │    └── Models
 │    ├── Store
 │    │    └── Models
 │    ├── Parser
 │    │    ├── Models
 │    │    └── Template
 │    │         └── Models
 │    └── Template
 ├── Models
 ├── Parser
 ├── Store
 └── swift-argument-parser

External dependencies:
  Parser    → Yams
  Engine    → Yams
  Store     → GRDB
  Engine    → swift-log
  Providers → swift-log
```

### Design Constraint: Web Server Readiness

`Engine` is the single source of truth. `CLI` is a thin client — no business logic. This ensures a future local web server can be built as another thin client over the same library.

`Models` is the leaf — pure value types, zero dependencies. Every other module depends on it.

---

## 3. Module — Models

**Purpose:** Pure value types and protocols shared across all modules. Leaf dependency — no internal or external dependencies.

### Key Types

```
Workflow            — top-level: name, description, inputs, nodes, output mapping,
                      cleanupPolicy: CleanupPolicy
WorkflowInput       — name, type (string), required flag, defaultValue: String?
                      Default is a raw template string resolved at workflow start
Node                — id, prompt, command, depends_on, output alias,
                      when, loop config, interactive mode,
                      nested workflow ref + inputs, workspaceMode: WorkspaceMode?
                      Resolvable fields (literal or {{template}}):
                        agent: Resolvable<String>?,
                        timeoutSeconds: Resolvable<Int>?,
                        onFailure: Resolvable<FailureStrategy>,
                        retryConfig: RetryConfig?, loopConfig: LoopConfig?
                      parameters: [String: Resolvable<String>] — provider-specific key-value pairs
InteractiveMode     — enum: .session, .prompt(message:)
LoopConfig          — until (evaluator name),
                      maxIterations: Resolvable<Int>,
                      freshContext: Resolvable<Bool>
RetryConfig         — maxAttempts: Resolvable<Int>,
                      delaySeconds: Resolvable<Int>
FailureStrategy     — enum: .stop, .skip, .continue
WorkspaceMode       — enum: .shared, .isolated
NodeStatus          — enum: .pending, .running, .awaitingInput, .completed,
                      .failed, .skipped, .cancelled
RunStatus           — enum: .pending, .running, .awaitingInput, .completed,
                      .failed, .cancelled
Run                 — id, workflow name/file, status, workspace path, inputs,
                      output, cleanup policy, timestamps
NodeExecution       — id, run_id, node_id, status, agent, attempt, iteration,
                      prompt, message, output, error, tmux session, timestamps
EvaluatorDefinition — name, type (ai/script/workflow), agent, prompt, command
EvaluatorType       — enum: .ai, .script, .workflow
CleanupPolicy       — enum: .duration(days:), .onSuccess, .always, .never
TaskContext         — inputs dict, resolved outputs dict, node statuses dict,
                      workspace path, environment dict (from .env + process env)
TaskOutput          — output text, exit status
LogEntry            — node_execution_id, stream (stdout/stderr), file path, timestamp
LogStream           — enum: .stdout, .stderr
RunStats            — run_id, workflow name, status, node count, duration, completed_at
ProcessResult       — exit code, stdout path, stderr path
Resolvable<T>       — enum: .literal(T), .template(String)
                      Generic wrapper for values that may be template strings
                      Conforms to Sendable, Equatable, Codable
ResolvableConvertible — protocol for types convertible from resolved strings
                        Requires init?(rawValue: String)
                        Conformers: Int, Bool, String, FailureStrategy,
                        WorkspaceMode
```

### Protocols

Defined here, implemented in their respective modules. All concrete implementations are `internal`.

| Protocol | Implemented By | Module |
|---|---|---|
| `AgentProviding` | `ClaudeCodeProvider`, `ShellProvider`, `CLIAgentProvider` | Providers |
| `EvaluatorProviding` | `EvaluatorProvider` | Engine |
| `WorkflowStoring` | `WorkflowStore` | Store |
| `TemplateResolving` | `TemplateResolver` | Template |
| `ExpressionEvaluating` | `ExpressionEvaluator` | Template |
| `WorkflowParsing` | `WorkflowParser` | Parser |
| `ProcessRunning` | `ProcessRunner` | Providers |
| `TmuxProviding` | `TmuxSession` | Providers |

All types are `Sendable`. Models are structs/enums — no classes, no mutable state. All error types conform to `CustomStringConvertible`.

### Test Strategy

- Round-trip encoding/decoding for any type that crosses a serialization boundary (JSON for SQLite columns, YAML for workflow files)
- Enum exhaustiveness — verify all cases are handled where relevant
- Equality and hashing where conformances are declared

---

## 4. Module — Template

**Purpose:** Resolves `{{variable}}` template syntax and evaluates `when:` guard expressions. Pure logic — no I/O, no side effects.

### Key Types

```
TemplateResolver    — resolves {{variable}} references against a context
                      Handles: inputs, {{node_id.output}}, {{node_id.status}},
                      output aliases, {{workspace}}, {{last_output}}
                      Handles \{{ escape → literal {{

ExpressionEvaluator — parses and evaluates when: guard expressions
                      Operators: ==, !=, &&, ||, !
                      Grouping: ()
                      Values: resolved template variables, string literals ('...')
                      All comparisons are string-based
```

### Protocols

| Protocol | Type |
|---|---|
| `TemplateResolving` | `resolve(template:context:) throws -> String` |
| `ExpressionEvaluating` | `evaluate(expression:context:) throws -> Bool` |

### Resolvable Types

Defined in the Models module, used by Template for resolution:

```
Resolvable<T>       — enum: .literal(T) | .template(String)
                      Represents a value that is either known at parse time
                      or deferred to execution time as a {{template}} string.
                      Conforms to Sendable, Equatable, Codable.

ResolvableConvertible — protocol requiring init?(rawValue: String)
                        Used by TemplateResolver to convert a resolved
                        template string into the target type T.
                        Conformers: Int, Bool, String, FailureStrategy,
                        WorkspaceMode.
```

`TemplateResolver` gains a method: `resolve<T: ResolvableConvertible>(resolvable:context:) throws -> T` that resolves `.template` values and converts the result, or returns `.literal` values directly.

### Errors

```
TemplateError
  .unresolvedVariable(name:)     — variable not found in context
  .malformedTemplate(detail:)    — unclosed {{ or invalid syntax
  .expressionSyntax(detail:)     — malformed when: expression
  .expressionEvaluation(detail:) — runtime eval failure (e.g., missing operand)
  .invalidConversion(value:targetType:) — resolved string cannot convert to T
```

### Design Notes

- Template resolution is a single pass: scan for `{{...}}`, look up in context, substitute. `\{{` produces literal `{{`.
- Expression evaluation: tokenize → parse into AST → evaluate. The AST is small — just binary ops, unary not, grouping, and string literals. No need for a general-purpose expression engine.
- Both are stateless — instantiate, call, discard. No actors needed.

### Test Strategy

- Variable resolution: inputs, node outputs, status refs, aliases, `{{workspace}}`, `{{last_output}}`
- Escape handling: `\{{` → literal `{{`
- Unresolved variable errors
- Expression evaluation: each operator, precedence, grouping, negation
- Complex expressions: `{{a.status}} == 'completed' && {{b.status}} == 'completed'`
- Resolvable resolution: `.literal` returns directly, `.template` resolves and converts
- Resolvable type conversion: valid string-to-Int, string-to-Bool, invalid conversions throw `.invalidConversion`
- Edge cases: empty strings, single-quote escaping (`\'`), whitespace in expressions

---

## 5. Module — Parser

**Purpose:** Loads YAML workflow files, validates them, and produces `Workflow` model instances. Single external dependency: Yams.

### Key Types

```
WorkflowParser      — parses YAML string/file into a validated Workflow model
                      Steps: deserialize YAML → map to models → validate

ValidationResult    — collection of validation errors/warnings
```

### Protocol

| Protocol | Type |
|---|---|
| `WorkflowParsing` | `parse(yaml:) throws -> Workflow`, `parse(file:) throws -> Workflow`, `validate(workflow:) -> ValidationResult` |

### Validation Checks

- YAML syntax (delegated to Yams)
- Required fields present (`name`, at least one node, each node has `id`)
- Node IDs are unique
- `depends_on` references exist and form a DAG (no circular deps outside loops)
- `agent` is present for non-interactive, non-workflow nodes
- `interactive: prompt` nodes have a `message` field
- `workflow:` nodes have `inputs:` mapping (optional if child workflow has defaults for all required inputs)
- Template variables reference valid inputs or upstream node IDs (output and status refs)
- Output aliases don't collide with node IDs or input names
- `until:` evaluator names are syntactically valid (resolution happens at runtime)
- `when:` expressions parse without syntax errors
- `on_failure`, `interactive`, `cleanup` values are from allowed enums

### Errors

```
ParserError
  .yamlSyntax(detail:)             — Yams parse failure
  .missingField(node:field:)       — required field absent
  .duplicateNodeID(id:)            — two nodes share an ID
  .circularDependency(cycle:)      — cycle detected in DAG
  .invalidReference(node:ref:)     — depends_on or template ref to nonexistent node
  .invalidExpression(node:detail:) — when: expression won't parse
  .validation(errors:)             — wraps multiple ValidationResult errors
```

### Design Notes

- Yams deserializes into untyped dictionaries first, then the parser maps to `Workflow`/`Node` models manually. This gives control over error messages rather than relying on `Codable` failures. `Node` references use `Models.Node` to disambiguate from `Yams.Node`.
- DAG validation uses topological sort — if it fails, extract the cycle for the error message.
- Template variable validation reuses `TemplateResolving` in a dry-run mode (resolve against known input names and node IDs without actual values).

### Test Strategy

- Valid workflow round-trips: YAML string → `Workflow` model → verify all fields
- Each validation rule has a dedicated test with a YAML snippet that triggers it
- Circular dependency detection with various graph shapes (self-loop, two-node cycle, deep cycle)
- Template variable validation: valid refs pass, invalid refs produce clear errors
- Edge cases: empty nodes list, node with no `depends_on`, duplicate output aliases
- Malformed YAML: missing colons, bad indentation, non-string values where strings expected

---

## 6. Module — Store

**Purpose:** SQLite persistence for runs, node executions, logs, and stats. Single external dependency: GRDB.

### Key Types

```
WorkflowStore       — actor, owns a GRDB DatabaseQueue
                      Manages connection lifecycle, WAL mode, migrations

MigrationManager    — applies schema migrations on startup via GRDB's
                      built-in DatabaseMigrator (no custom schema_version table)
```

### Protocol

```
WorkflowStoring
  // Runs
  createRun(_:) async throws -> Run
  getRun(id:) async throws -> Run?
  updateRunStatus(id:status:) async throws
  updateRunOutput(id:output:) async throws
  listRuns(status:) async throws -> [Run]
  deleteRuns(olderThan:status:) async throws

  // Node executions
  createNodeExecution(_:) async throws -> NodeExecution
  getNodeExecutions(runID:nodeID:) async throws -> [NodeExecution]
  updateNodeExecution(id:status:output:error:) async throws
  getAwaitingInput(runID:) async throws -> [NodeExecution]

  // Logs
  createLogEntry(nodeExecutionID:stream:filePath:) async throws
  getLogEntries(nodeExecutionID:) async throws -> [LogEntry]

  // Stats
  recordStats(run:nodeCount:duration:) async throws
  getStats() async throws -> [RunStats]

  // Lifecycle
  runRetentionPurge(retentionDays:status:) async throws
```

### Errors

```
StoreError
  .databaseNotFound(path:)          — .orc/orc.db doesn't exist
  .migrationFailed(version:detail:) — schema migration failure
  .recordNotFound(table:id:)        — query returned no rows
  .writeFailure(detail:)            — insert/update failed
```

### Design Notes

- `WorkflowStore` is an actor — serializes all write access. Uses GRDB's `DatabaseQueue` with WAL mode enabled.
- WAL mode enabled at database creation (`orc init`), not per-connection.
- Schema migrations are sequential, numbered, and applied on startup before any command executes. Each migration is a function: `(Database) throws -> Void`.
- Run ID generation (8-char alphanumeric) lives here — the store guarantees uniqueness via primary key.
- Log content is in workspace files; the `logs` table stores file paths only.
- `stats` table is never affected by purge operations.
- Retention purge runs on startup — lightweight query, deletes matching run records + node executions + log entries. Workspace file cleanup is a separate concern (Engine coordinates).

### Test Strategy

- In-memory GRDB database for all tests — no disk I/O, fast teardown
- CRUD round-trips: create → read → update → verify for runs and node executions
- Migration tests: apply each migration sequentially, verify schema state after each
- Purge: create runs with various statuses and ages, verify correct ones are deleted and stats survive
- Concurrent reads: multiple async reads during a write — verify no data races
- Edge cases: duplicate run ID insert fails, update nonexistent record throws `.recordNotFound`

---

## 7. Module — Providers

**Purpose:** Agent provider implementations. Each provider knows how to execute a prompt (non-interactive) and optionally run an interactive tmux session.

### Key Types

```
ClaudeCodeProvider  — runs `claude -p "prompt" --output-format json --permission-mode <mode>`
                      Reads permission_mode, bare, model from parameters dict
                      Defines ClaudePermissionMode enum (provider-specific, not in Models)
                      Parses JSON response, extracts text output
                      Passes TaskContext.environment to child process
                      Interactive: launches `claude` in tmux session

ShellProvider       — runs command via Foundation Process
                      Captures stdout as output, stderr to log files
                      Interactive: launches command in tmux session

CLIAgentProvider    — wraps any CLI tool configured in .orc/config.yml
                      Substitutes {{prompt}} into configured command template
                      Interactive: uses configured interactive_command in tmux

TmuxSession         — creates, attaches, destroys tmux sessions
                      Named: orc-<run-id>-<node-id>
                      Captures output on session exit

ProcessRunner       — thin wrapper around Foundation Process
                      Stdout/stderr streaming to files
                      Timeout enforcement (SIGTERM → 5s → SIGKILL)
                      Sendable — stateless, captures only config

ProviderRegistry    — resolves agent names to AgentProviding implementations
                      Registers built-in and custom CLI agent providers
```

### Protocols

| Protocol | Implemented By | Purpose |
|---|---|---|
| `AgentProviding` | `ClaudeCodeProvider`, `ShellProvider`, `CLIAgentProvider` | Agent execution |
| `ProcessRunning` | `ProcessRunner` | Abstracts process execution for testability |
| `TmuxProviding` | `TmuxSession` | Abstracts tmux operations for testability (includes `sessionExists(name:)`) |

### Errors

```
ProviderError
  .processFailure(command:exitCode:stderr:)
  .timeout(command:seconds:)
  .tmuxFailure(session:detail:)
  .outputParseFailure(provider:detail:) — e.g., claude JSON response malformed
  .providerNotFound(name:)              — agent name not in config
```

### Design Notes

- `ProcessRunning` and `TmuxProviding` protocols exist purely for testability — tests inject fakes instead of spawning real processes.
- `ClaudeCodeProvider` parses the `--output-format json` response to extract text content. If the JSON structure changes, only this provider needs updating. It reads `permission_mode`, `bare`, and `model` from the `parameters` dict to build CLI arguments dynamically.
- `CLIAgentProvider` is generic — reads command template from config, substitutes `{{prompt}}`, runs it. One implementation covers codex, aider, and any future CLI tool.
- Timeout enforcement: `ProcessRunner` sends SIGTERM, waits 5 seconds, sends SIGKILL. Same logic for cancellation.
- tmux is a runtime dependency only when `interactive: session` nodes are used. Providers check for tmux availability and throw a clear error if missing.

### Test Strategy

- Fake `ProcessRunning` / `TmuxProviding` for all provider tests — no real subprocesses
- `ClaudeCodeProvider`: verify correct CLI arguments, JSON output parsing, error on malformed JSON
- `ShellProvider`: verify stdout capture, stderr routing, exit code handling
- `CLIAgentProvider`: verify `{{prompt}}` substitution in command template
- Timeout: fake process that never exits → verify SIGTERM/SIGKILL sequence
- Interactive: verify tmux session naming convention, create/destroy lifecycle
- Provider resolution: config with custom agents → correct provider returned; unknown agent → `.providerNotFound`

---

## 8. Module — Engine

**Purpose:** The orchestrator. Resolves the DAG, dispatches nodes, manages loops, evaluators, interactive nodes, resume, and cancellation. This is the largest module — it ties everything together.

### Key Types

```
WorkflowEngine      — actor, entry point for the library
                      start(workflowFile:inputs:maxParallelNodes:) → Run
                      resume(runID:) → Run
                      cancel(runID:)
                      respond(runID:nodeID:response:) — for prompt-interactive nodes
                      Exposes query API: listRuns(), getStatus(), getLogs(), getStats()
                      Calls startup retention purge during initialization

ExecutionPlanner    — builds DAG from Workflow, computes topological order,
                      validates dependency graph

ExecutionPlan       — resolved DAG with topological order, ready for dispatch

NodeDispatcher      — walks the DAG using TaskGroup
                      Dispatches ready nodes concurrently (respects max_parallel_nodes)
                      Evaluates when: guards before dispatch
                      Updates context as nodes complete
                      Handles nested workflow execution for workflow-type nodes

LoopHandler         — manages sequential loop iterations for a node
                      Invokes provider → runs evaluator → checks max_iterations
                      Handles fresh_context flag

InteractiveHandler  — manages interactive node lifecycle
                      Session: coordinates tmux create/attach/destroy via provider
                      Prompt: sets awaiting_input, stores message, processes responses

EvaluatorRunner     — resolves evaluator by name (built-in → .orc/evaluators/)
                      Loads custom evaluators from `.orc/evaluators/` YAML files
                      Runs the evaluator: AI → provider, script → shell, workflow → recursive
                      Parses result to boolean

ResumeHandler       — loads failed/cancelled run from store
                      Re-parses current workflow YAML
                      Validates completed nodes still exist
                      Resets state, re-executes from failure point

CancellationHandler — sends SIGTERM/SIGKILL to running processes
                      Destroys tmux sessions
                      Marks pending nodes as cancelled

ResolvedNodeConfig  — internal struct, produced from Node at dispatch time
                      All Resolvable fields resolved to concrete values:
                        agent: String?, timeoutSeconds: Int?,
                        onFailure: FailureStrategy, parameters: [String: String],
                        retryConfig: ResolvedRetryConfig?,
                        loopConfig: ResolvedLoopConfig?
                      Created by NodeDispatcher using TemplateResolver

ResolvedRetryConfig — maxAttempts: Int, delaySeconds: Int

ResolvedLoopConfig  — until: String, maxIterations: Int, freshContext: Bool

DefaultMerger       — fills missing workflow inputs from WorkflowInput.defaultValue
                      Resolves default template strings against available context
                      Runs once at workflow start before any node dispatches

WorkspaceManager    — creates workspace directories per run
                      Handles cleanup policies (duration, on_success, always, never)
                      Startup purge of expired workspaces

DotEnvLoader        — loads .env file from .orc/ directory (KEY=VALUE format)
                      Supports comments, quoted values, inline comments
                      Merges with process environment (process env wins on conflict)
                      Result flows into TaskContext.environment

ConfigManager       — loads/merges config: CLI flags > workflow YAML > .orc/config.yml > defaults
                      YAML-aware read/write for orc config commands
                      Parses providers section from config for custom CLI agents

OrcConfig           — top-level config model (concurrency, storage, providers)
ProviderConfig      — per-provider config (path, type, command, interactive_command)
```

### Protocols

| Protocol | Implemented By |
|---|---|
| `EvaluatorProviding` | `EvaluatorRunner` |

### Errors

```
EngineError
  .workflowAlreadyRunning(id:)
  .runNotFound(id:)
  .runNotResumable(id:status:)         — status isn't failed/cancelled
  .workspaceNotFound(runID:)           — cleaned up, can't resume
  .completedNodeRemoved(nodeID:)       — resume: completed node missing from updated YAML
  .nodeNotAwaitingInput(nodeID:status:)
  .evaluatorNotFound(name:)
  .evaluatorFailed(name:detail:)       — evaluator itself crashed
  .maxIterationsReached(nodeID:count:)
  .dependencyFailed(nodeID:upstream:)  — all deps skipped, node can't run
  .nestedWorkflowFailed(nodeID:detail:) — child workflow execution failed
  .missingRequiredInput(name:workflow:)  — required input without default not provided by caller
  .invalidConfigValue(field:value:detail:) — Resolvable resolved to unconvertible value
```

### Design Notes

- `WorkflowEngine` is the single public actor — CLI and future web server both go through it. Internal types (`NodeDispatcher`, `LoopHandler`, `DefaultMerger`, etc.) are `internal`.
- **Default merging:** at workflow start (before any node dispatches), `DefaultMerger` iterates the workflow's declared inputs and fills any missing caller-provided values from `WorkflowInput.defaultValue`. Default values are template strings resolved against the available context (other inputs already provided). After merging, the engine validates that all required inputs are present — any still missing produce `.missingRequiredInput`.
- **Resolvable resolution:** `NodeDispatcher` resolves all `Resolvable` fields on a node just before dispatch, producing a `ResolvedNodeConfig`. Template strings are resolved via `TemplateResolver` and converted to the target type. Conversion failures produce `.invalidConfigValue`.
- `NodeDispatcher` uses `TaskGroup` to run ready nodes concurrently. As each node completes, it checks which downstream nodes become unblocked and dispatches them. `max_parallel_nodes` is enforced via a semaphore or bounded task group.
- Dependency satisfaction rule: a node runs if at least one dep completed or failed-with-continue. Skipped only if all deps were skipped.
- Loop iterations are always sequential within a node. `LoopHandler` owns the iteration cycle: invoke provider → capture output → run evaluator → decide continue/stop.
- Evaluator failure (crash, unexpected error) is treated as a node failure, not "false". Prevents infinite loops from broken evaluators.
- Resume creates new `node_executions` rows — never overwrites history.
- Cancellation is cooperative: SIGTERM first, SIGKILL after 5s. Already-running nodes are allowed to finish their current operation before the kill signal.
- `ConfigManager` merges the precedence chain at startup. `orc config set` does YAML-aware editing (comments are not preserved — documented tradeoff).

### Test Strategy

- **DAG resolution:** various graph shapes — linear, diamond, fan-out/fan-in, disconnected parallel branches. Verify topological order and concurrent dispatch.
- **Node dispatch:** fake providers that return canned outputs. Verify context propagation (node A output available to node B).
- **when: guards:** node skipped when false, downstream branching works (one of N paths taken, converge node runs).
- **Skip cascading:** all deps skipped → node skipped. Mix of skipped + completed → node runs.
- **Failure strategies:** `stop` halts run, `skip` cascades, `continue` satisfies downstream deps.
- **Loops:** verify sequential iteration, evaluator called after each, `max_iterations` respected, `fresh_context` produces new provider calls.
- **Evaluator failure:** evaluator throws → node fails (not infinite loop).
- **Interactive prompt:** set awaiting_input → respond → output captured. Respond to wrong status → error.
- **Interactive session:** fake tmux provider → verify session lifecycle.
- **Resume:** completed nodes skipped, failed node re-executed, downstream runs. Removed completed node → error. Modified YAML with new nodes → works.
- **Cancellation:** running nodes get SIGTERM, pending nodes marked cancelled, tmux sessions destroyed.
- **Nested workflows:** child workflow executes, output flows to parent. Child failure → parent failure. Shared vs isolated workspace. Caller validation: missing required input without default → `.missingRequiredInput`. Inputs with defaults: omitted input filled from default. All defaults → `inputs:` mapping omittable.
- **Default merging:** workflow with defaults fills missing inputs. Template defaults resolved against provided inputs. Missing required input after merge → error.
- **Resolvable config:** template `agent` field resolves at dispatch. Template `timeout_seconds` converts to Int. Invalid conversion → `.invalidConfigValue`. Literal values pass through unchanged.
- **Concurrency:** `max_parallel_nodes` respected — dispatch N nodes, verify no more than N run concurrently (use async semaphore counting in fakes).

---

## 9. Module — CLI

**Purpose:** Thin executable target. Parses arguments, calls `Engine`, formats output. Zero business logic. Depends on Engine, Models, Parser, and Store directly (e.g., `ValidateCommand` uses `WorkflowParser` directly, `InitCommand` creates `WorkflowStore` directly).

### Key Types

Subcommand implementations live in `CLI/Source/Commands/`. Shared utilities (`Formatting`, `OrcDirectory`, `OrcVersion`) are at `CLI/Source/` level. Version is defined in `OrcVersion.swift` as the single source of truth.

```
OrcCommand          — root command, @main entry point
                      Subcommands: Init, Validate, Start, Resume, List,
                      Status, Attach, Respond, Logs, Cancel, Cleanup,
                      Purge, Stats, Config, Version

Init                — creates .orc/ directory, database, default config
Validate            — parses workflow YAML, prints validation errors
Start               — starts a workflow run, prints run ID
                      Options: --input key=value (repeatable), --max-parallel-nodes N
Resume              — resumes failed/cancelled run
List                — lists runs, optional --status filter
Status              — shows run progress, node states, attach/respond hints
Attach              — connects terminal to tmux session (exec into tmux attach)
Respond             — sends text or --file to a prompt-interactive node
Logs                — prints log content, optional --node, --attempt, --iteration filters
Cancel              — cancels a running workflow
Cleanup             — removes workspace for a specific run
Purge               — deletes old runs, optional --older-than, --status filters
Stats               — prints DB size, run counts, timing summaries
Config              — get/set/unset config values (dot notation)
Version             — prints version, build info, Swift runtime
```

### External Dependency

swift-argument-parser

### Design Notes

- Each subcommand is a struct conforming to `AsyncParsableCommand`.
- All subcommands instantiate `WorkflowEngine` and call its public API. No logic beyond argument mapping and output formatting.
- Output formatting is plain text for v1. Structured for terminals — status uses aligned columns, logs stream line-by-line.
- `orc attach` uses `execvp` to replace the process with `tmux attach-session`. No intermediate wrapping.
- Exit codes: 0 success, 1 general error, 2 validation error. Errors print to stderr.
- `.orc/` discovery: walk up parent directories from cwd until found (like `.git/`). Commands that need it (all except `init` and `version`) fail with a clear message if not found.

### Test Strategy

- CLI target itself has minimal tests — integration-level only.
- Argument parsing: verify each subcommand parses valid flags and rejects invalid ones (swift-argument-parser provides test utilities for this).
- `.orc/` discovery: test walk-up logic with temp directories.
- All actual behavior is tested via Engine module tests. CLI tests only verify the wiring is correct.
