# Orc CLI — Design Spec

An open-source Swift CLI for orchestrating AI agents running tasks. Workflows are defined in YAML with a functional model (input → task → output), executed as dependency graphs with automatic parallelization, and persisted in a local SQLite database.

---

## 1. YAML Workflow Schema

A workflow file declares metadata, typed inputs, a list of nodes, and an output mapping.

```yaml
name: "implement-feature"
description: "Plan and implement a feature"
input:
  - name: repo_path
    type: string
    required: true
  - name: feature_description
    type: string
    required: true

nodes:
  - id: plan
    agent: claude-code
    prompt: "Explore {{repo_path}} and create a plan for: {{feature_description}}"
    output: plan_file

  - id: implement
    agent: claude-code
    depends_on: [plan]
    loop:
      prompt: "Read {{plan_file}}. Implement the next incomplete task. Run validation."
      until: all_tasks_complete    # references an evaluator by name
      max_iterations: 20
      fresh_context: true

  - id: lint
    agent: shell
    depends_on: [implement]
    command: "cd {{repo_path}} && swift build 2>&1"

  - id: review
    agent: github-copilot
    depends_on: [lint]
    prompt: "Review the changes in {{repo_path}} for correctness and style"

  - id: approve
    depends_on: [review]
    loop:
      prompt: "Present the changes for review. Address any feedback."
      until: approved
      interactive: true            # pauses and waits for human input

output:
  summary: "{{review.output}}"
```

### Key concepts

- **`{{variable}}`** — template syntax for referencing inputs, upstream outputs (`{{node_id.output}}`), and built-in variables (`{{workspace}}`).
- **`agent`** — selects the provider: `claude-code`, `github-copilot`, `shell`.
- **`depends_on`** — list of node IDs that must complete before this node runs. Nodes with no unmet dependencies run concurrently.
- **`loop`** — repeats execution until an evaluator returns true or `max_iterations` is reached. `fresh_context: true` spawns a new process each iteration (no conversation carry-over).
- **`interactive: true`** — launches the agent in an interactive tmux session and pauses the workflow until the user completes the interaction. When the user exits the tmux session, the evaluator runs on the captured session output to determine whether the loop continues or exits.
- **Nested workflows** — a node can reference another workflow file via `workflow: path/to/other.yml` instead of `agent`/`prompt`. The nested workflow receives inputs and its output flows back to the parent.

---

## 2. Evaluators

Evaluators are named boolean functions that determine loop exit conditions. They receive input (typically the last node output) and return true/false.

### Evaluator types

| Type | How it runs | True condition |
|---|---|---|
| `ai` | Sends prompt to an agent | Agent response parses as true/yes |
| `script` | Runs a shell command | Exit code 0 |
| `workflow` | Runs another workflow | Final output is true |

### Definition

Evaluators are defined in YAML files:

```yaml
# evaluators/all-tasks-complete.yml
name: all_tasks_complete
type: ai
agent: claude-code
prompt: "Review the plan and implementation. Are all tasks complete? Answer only YES or NO."
output: boolean
```

```yaml
# evaluators/tests-pass.yml
name: tests_pass
type: script
command: "cd {{workspace}} && swift test"
```

### Built-in evaluators

The engine ships with built-in evaluators: `max_iterations_reached`, `output_unchanged`, `exit_code_zero`. Users define custom evaluators via YAML and reference them by name in `until:` fields.

---

## 3. Project Structure

Monorepo layout — the CLI is one project under `Orc/`, with sibling projects alongside it.

```
Orc/
├── CLI/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── CLI/                  # Executable target (thin layer over OrcEngine)
│   │   └── OrcEngine/            # Library target (all core logic)
│   │       ├── Models/           # Workflow, Node, TaskResult, Evaluator, etc.
│   │       ├── Parser/           # YAML parsing & validation
│   │       ├── Engine/           # DAG resolver, executor, loop handler
│   │       ├── Providers/        # AgentProvider protocol + implementations
│   │       ├── Store/            # SQLite state persistence
│   │       └── Template/         # {{variable}} resolution
│   └── Tests/
│       └── OrcEngineTests/
├── <future-sibling-projects>/
└── docs/
```

### Design constraint: web server readiness

OrcEngine is the single source of truth. The CLI is a thin client over the engine — no business logic in the CLI layer. This ensures a future local web server can be built as another thin client over the same library.

- OrcEngine exposes a query-friendly API: `listRuns()`, `getStatus(runId:)`, `getLogs(runId:nodeId:)`, `getStats()`, etc.
- SQLite uses WAL mode for concurrent read/write access (CLI and future web server can operate simultaneously).

---

## 4. Execution Flow

When `orc start workflow.yml --input repo_path=. --input feature_description="add auth"` is run:

### 4.1 Parse

YAML is loaded, validated, and deserialized into a `Workflow` model. Template variables are checked against declared inputs. Evaluator references are resolved.

### 4.2 Plan

Nodes are resolved into an `ExecutionPlan` — a directed acyclic graph. Dependencies are validated (no missing refs, no circular deps outside of loop nodes). Topological order is computed.

### 4.3 Persist

A new workflow run is created in SQLite with a generated short UUID. Status: `running`. The workspace directory is created. The run ID is printed to stdout.

### 4.4 Execute

The executor walks the plan using Swift Concurrency (`async/await`, `TaskGroup`):

- Nodes with no unmet dependencies are dispatched concurrently (subject to concurrency limits).
- Each node's `agent` is resolved to a provider. Template variables are substituted from the current context (inputs + upstream outputs).
- The provider is invoked. On completion, the node's output is stored in SQLite and the context is updated for downstream nodes.

**Loops:** The executor re-invokes the node's provider in a cycle. After each iteration, the evaluator runs on the output. `fresh_context: true` spawns a new process per iteration. The loop stops when the evaluator returns true or `max_iterations` is reached.

**Interactive nodes:** When `interactive: true`:
1. The agent CLI is launched in a tmux session named `orc-<run-id>-<node-id>`.
2. The node status is set to `awaiting_input` in SQLite.
3. `orc status <id>` shows: `approve: awaiting_input — attach with: orc attach <id> approve`.
4. `orc attach <id> <node-id>` connects the user's terminal to the tmux session.
5. When the user finishes, the evaluator runs on the session output.
6. Other independent nodes continue executing — only this node's branch is paused.

tmux is a runtime dependency only for interactive nodes.

### 4.5 Complete

Once all nodes finish, the run status is set to `completed` (or `failed`). Final output is stored. Stats are written. Workspace cleanup runs according to the configured policy.

---

## 5. Provider Abstraction

```swift
protocol AgentProvider {
    var name: String { get }
    func execute(prompt: String, context: TaskContext) async throws -> TaskOutput
    func executeInteractive(prompt: String, context: TaskContext, sessionName: String) async throws -> TaskOutput
}
```

### Built-in providers

| Provider | Non-interactive | Interactive |
|---|---|---|
| `claude-code` | `claude -p "prompt" --output-format json` | `claude` in tmux session |
| `github-copilot` | `gh copilot suggest "prompt"` (or equivalent headless mode) | `gh copilot` in tmux session |
| `shell` | `Process` with stdout/stderr capture | Command in tmux session |

### Provider configuration

```yaml
# .orc/config.yml
providers:
  claude-code:
    path: /usr/local/bin/claude    # default: looks in PATH
    default_model: opus
  github-copilot:
    path: /usr/local/bin/gh
  shell:
    default_shell: /bin/zsh
```

Custom providers can be added by implementing the `AgentProvider` protocol.

---

## 6. SQLite Schema

```sql
-- Workflow runs
CREATE TABLE runs (
    id TEXT PRIMARY KEY,
    workflow_name TEXT NOT NULL,
    workflow_file TEXT NOT NULL,
    status TEXT NOT NULL,           -- pending, running, awaiting_input, completed, failed
    workspace_path TEXT NOT NULL,
    inputs TEXT,                    -- JSON
    output TEXT,
    cleanup_policy TEXT NOT NULL DEFAULT 'on_success',
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL
);

-- Node executions (one row per attempt)
CREATE TABLE node_executions (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    node_id TEXT NOT NULL,
    status TEXT NOT NULL,           -- pending, running, awaiting_input, completed, failed, skipped
    agent TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 1,
    prompt TEXT,
    output TEXT,
    error TEXT,
    tmux_session TEXT,
    started_at TIMESTAMP,
    completed_at TIMESTAMP
);

-- Append-only logs
CREATE TABLE logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_execution_id TEXT NOT NULL REFERENCES node_executions(id),
    stream TEXT NOT NULL,           -- stdout, stderr
    content TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL
);

-- Historical stats (never pruned)
CREATE TABLE stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    workflow_name TEXT NOT NULL,
    status TEXT NOT NULL,
    node_count INTEGER NOT NULL,
    duration_seconds REAL,
    completed_at TIMESTAMP NOT NULL
);
```

---

## 7. Workspace Management

Each workflow run gets a temporary directory:

```
/tmp/orc/<run-id>/
├── workspace/    # cloned repos, generated files
├── artifacts/    # outputs agents produce
└── logs/         # raw stdout/stderr per node per attempt
```

The path is tracked in SQLite. `{{workspace}}` is a built-in template variable available in all nodes.

### Cleanup policy

Configurable per workflow or globally:

```yaml
workspace:
  cleanup: on_success   # options: on_success, always, never
```

- `on_success` (default) — workspace is deleted when the run completes successfully.
- `always` — workspace is deleted when the run finishes regardless of outcome.
- `never` — workspace is retained until manually removed via `orc cleanup <run-id>`.

---

## 8. Error Handling & Resilience

### Per-node configuration

```yaml
- id: deploy
  agent: shell
  command: "deploy.sh"
  retry:
    max_attempts: 3        # default: 1 (no retry)
    delay_seconds: 5       # default: 0
  timeout_seconds: 300     # default: none
  on_failure: stop         # stop (default), skip, continue
```

### Failure strategies

- **`stop`** — marks the run as `failed`. No further nodes are dispatched. Nodes already running are allowed to finish.
- **`skip`** — marks the node as `skipped`. Downstream nodes that depend on it are also skipped.
- **`continue`** — marks the node as `failed` but the workflow continues. Downstream nodes run with the failed node's output as empty.

### Timeout

If a node exceeds `timeout_seconds`, the process is killed and treated as a failure. Retries apply if configured.

All stdout/stderr from every invocation is logged regardless of outcome.

---

## 9. Concurrency Configuration

```yaml
# .orc/config.yml
concurrency:
  max_parallel_nodes: 4    # default: number of CPU cores
  max_parallel_agents: 2   # default: 2
```

Overridable via CLI flags: `orc start workflow.yml --max-parallel-agents 1`.

---

## 10. Storage & Retention

### Database location

SQLite database lives at `.orc/orc.db` within the project.

### Auto-retention

```yaml
# .orc/config.yml
storage:
  retention_days: 30               # auto-purge runs older than this
  retention_policy: completed_only # completed_only (default), all, none
```

Purge check runs on startup — lightweight query before any command executes.

### Manual purge

`orc purge [--older-than 30d] [--status completed|failed|all]` deletes matching runs and their workspace folders.

---

## 11. CLI Commands

```
orc init
    Creates .orc/ in the current directory with config.yml, orc.db,
    and workflows/ containing built-in workflow templates.

orc start <workflow.yml> [--input key=value]... [--max-parallel-agents N]
    Starts a workflow run, prints the run ID.

orc list [--status running|completed|failed]
    Lists all runs with status and timestamps.

orc status <run-id>
    Shows run progress: each node's state, current loop iteration, etc.

orc attach <run-id> <node-id>
    Attaches to an interactive node's tmux session.

orc logs <run-id> [--node <node-id>] [--attempt N]
    Prints captured logs.

orc cancel <run-id>
    Cancels a running workflow, kills active processes.

orc cleanup <run-id>
    Manually removes the workspace for a completed/failed run.

orc purge [--older-than 30d] [--status completed|failed|all]
    Deletes old runs, their logs, and workspace folders.

orc stats
    Reports: DB path and size, total runs by status, active workspace
    count and disk usage, config file location and key settings.

orc config
    Lists all current config values.

orc config <key>
    Gets a specific config value.

orc config <key> <value>
    Sets a config value.

orc config --unset <key>
    Removes a config value, reverts to default.
```

Config keys use dot notation: `orc config concurrency.max_parallel_agents 4`.

---

## 12. Project Initialization

`orc init` creates:

```
.orc/
├── config.yml          # project config with defaults
├── orc.db              # SQLite database
└── workflows/          # built-in workflow templates
    ├── code-review.yml
    ├── implement-feature.yml
    └── ...
```

The `.orc/` directory is discovered by walking up parent directories (like `.git/`), so commands work from subdirectories.

---

## 13. Distribution

macOS only (arm64 and x86_64). Three channels:

1. **Homebrew** — `brew tap <owner>/orc && brew install orc`
2. **Build from source** — `git clone && cd Orc/CLI && swift build -c release`
3. **Release archive** — `.zip` from GitHub Releases:
   ```
   orc-v1.0.0-macos-arm64.zip
   ├── bin/orc
   └── workflows/
       ├── code-review.yml
       ├── implement-feature.yml
       └── ...
   ```

---

## 14. Future Considerations

- **Local web server** — a thin client over OrcEngine that serves a browser UI for monitoring workflows. The architecture supports this: OrcEngine is the single source of truth, SQLite uses WAL mode for concurrent access, and the engine exposes query-friendly APIs.
- **Linux support** — not in scope for v1, but no macOS-specific APIs are used in the engine layer.
- **Additional providers** — the `AgentProvider` protocol allows adding new AI providers without modifying the engine.
