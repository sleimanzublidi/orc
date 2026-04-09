# Orc CLI — Design Spec v2

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
    output: plan_file              # alias: {{plan_file}} = {{plan.output}}

  - id: implement
    agent: claude-code
    depends_on: [plan]
    loop:
      prompt: "Read {{plan_file}}. Implement the next incomplete task. Run validation."
      until: all_tasks_complete
      max_iterations: 20
      fresh_context: true

  - id: lint
    agent: shell
    depends_on: [implement]
    command: "cd {{repo_path}} && swift build 2>&1"

  - id: review
    agent: claude-code
    depends_on: [lint]
    interactive: session
    prompt: "Present the changes in {{repo_path}} for review. Address any feedback."

  - id: approve
    depends_on: [review]
    interactive: prompt
    message: "Review complete. Approve the changes? (yes/no)"
    loop:
      until: approved
      max_iterations: 5

  - id: get-image
    interactive: prompt
    message: "Provide the hero image file for the landing page"

  - id: sub-workflow
    workflow: workflows/deploy.yml
    depends_on: [approve]
    inputs:
      repo_path: "{{repo_path}}"
      environment: "staging"
    output: deploy_result

output:
  summary: "{{review.output}}"
  deploy: "{{deploy_result}}"
```

### Key concepts

- **`{{variable}}`** — template syntax for referencing inputs, upstream outputs (`{{node_id.output}}`), and built-in variables (`{{workspace}}`). Additionally, `{{node_id.status}}` is available to check whether an upstream node completed, failed, or was skipped.
- **`agent`** — selects the provider: `claude-code`, `shell`, or any custom CLI agent defined in config.
- **`depends_on`** — list of node IDs that must complete before this node runs. Nodes with no unmet dependencies run concurrently.
- **`output`** — optional alias for the node's output. `output: plan_file` means `{{plan_file}}` is equivalent to `{{plan.output}}`. If omitted, the output is only accessible via `{{node_id.output}}`.
- **`loop`** — repeats execution until an evaluator returns true or `max_iterations` is reached. `fresh_context: true` spawns a new process each iteration (no conversation carry-over). The loop output is the last iteration's output.
- **`interactive`** — two modes:
  - **`session`** — launches the agent in a tmux session. User attaches via `orc attach`. Requires `agent` field. Used for AI agents or tools that need an ongoing terminal session.
  - **`prompt`** — the engine pauses the node and displays a `message`. User responds via `orc respond` with text or a file. No running process. Does not require an `agent` field.
- **Nested workflows** — a node can reference another workflow file via `workflow:` instead of `agent`/`prompt`. The child workflow receives explicit `inputs:` and its final output flows back to the parent via `output:`.

---

## 2. Evaluators

Evaluators are named boolean functions that determine loop exit conditions. They receive the last node output and return true/false.

### Input contract

Every evaluator receives the last node output via the `{{last_output}}` template variable:

- **AI evaluators** — `{{last_output}}` is injected into the prompt template.
- **Script evaluators** — the last output is passed via stdin. It is also available as the `ORC_LAST_OUTPUT` environment variable.
- **Workflow evaluators** — the last output is passed as an input to the child workflow.

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
prompt: "Given this output:\n{{last_output}}\n\nReview the plan and implementation. Are all tasks complete? Answer only YES or NO."
output: boolean
```

```yaml
# evaluators/tests-pass.yml
name: tests_pass
type: script
command: "cd {{workspace}} && swift test"
```

### Built-in evaluators

- `approved` — for interactive prompt nodes. Returns true when the user responds with "yes", "y", "approve", or "approved" (case-insensitive).
- `exit_code_zero` — runs a command, true if exit code is 0.
- `output_unchanged` — compares current iteration output to previous, true if identical.

Users define custom evaluators via YAML and reference them by name in `until:` fields.

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

A new workflow run is created in SQLite with a generated short UUID. Status: `running`. The workspace directory is created under `.orc/workspaces/<run-id>/`. The run ID is printed to stdout.

### 4.4 Execute

The executor walks the plan using Swift Concurrency (`async/await`, `TaskGroup`):

- Nodes with no unmet dependencies are dispatched concurrently (subject to `max_parallel_nodes`).
- Each node's `agent` is resolved to a provider. Template variables are substituted from the current context (inputs + upstream outputs + `{{node_id.status}}` for each completed node).
- The provider is invoked. On completion, the node's output is stored in SQLite and the context is updated for downstream nodes.

**Loops:** The executor re-invokes the node's provider in a cycle. After each iteration, the evaluator receives the node's output (via `{{last_output}}`). `fresh_context: true` spawns a new process per iteration. The loop stops when the evaluator returns true or `max_iterations` is reached. The loop's output is the last iteration's output.

**Interactive session nodes (`interactive: session`):**
1. The agent CLI is launched in a tmux session named `orc-<run-id>-<node-id>`.
2. The initial prompt is sent to the agent.
3. Node status → `awaiting_input`.
4. `orc status <id>` shows: `review: awaiting_input — attach with: orc attach <id> review`.
5. `orc attach <id> <node-id>` connects the user's terminal to the tmux session.
6. When the process exits, the output is captured. If in a loop, the evaluator runs.
7. Other independent nodes continue executing — only this node's branch is paused.

tmux is a runtime dependency only for session-based interactive nodes.

**Interactive prompt nodes (`interactive: prompt`):**
1. Node status → `awaiting_input`. The `message` is stored in SQLite.
2. `orc status <id>` shows: `approve: awaiting_input — "Review complete. Approve the changes? (yes/no)"` and `Respond with: orc respond <id> approve <text or file>`.
3. User runs `orc respond <id> <node-id> <value>`.
4. The response becomes the node's output. If in a loop, the evaluator runs on the response.
5. No process is spawned. The engine itself manages the pause/resume.

### 4.5 Complete

Once all nodes finish, the run status is set to `completed` (or `failed`). Final output is stored. A row is written to the `stats` table. Workspace cleanup runs according to the configured policy.

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

| Provider | Non-interactive | Interactive (session) |
|---|---|---|
| `claude-code` | `claude -p "prompt" --output-format json` | `claude` in tmux session |
| `shell` | `Process` with stdout/stderr capture | Command in tmux session |

### Custom CLI agents

Any CLI tool can be used as a provider via configuration. The `cli-agent` provider wraps any command that accepts a prompt and produces output:

```yaml
# .orc/config.yml
providers:
  claude-code:
    path: /usr/local/bin/claude
    default_model: opus
  codex:
    type: cli-agent
    command: "codex -q '{{prompt}}'"
    interactive_command: "codex"    # for session mode
  aider:
    type: cli-agent
    command: "aider --message '{{prompt}}'"
    interactive_command: "aider"
  shell:
    default_shell: /bin/zsh
```

Nodes reference custom agents by name: `agent: codex`, `agent: aider`.

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

-- Node executions (one row per attempt per iteration)
CREATE TABLE node_executions (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    node_id TEXT NOT NULL,
    status TEXT NOT NULL,           -- pending, running, awaiting_input, completed, failed, skipped
    agent TEXT,                     -- null for prompt-based interactive nodes
    attempt INTEGER NOT NULL DEFAULT 1,
    iteration INTEGER NOT NULL DEFAULT 1,  -- loop iteration number
    prompt TEXT,
    message TEXT,                   -- for interactive prompt nodes
    output TEXT,
    error TEXT,
    tmux_session TEXT,              -- set for session-based interactive nodes
    started_at TIMESTAMP,
    completed_at TIMESTAMP
);

-- Log file references (actual content in workspace logs/ directory)
CREATE TABLE logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_execution_id TEXT NOT NULL REFERENCES node_executions(id),
    stream TEXT NOT NULL,           -- stdout, stderr
    file_path TEXT NOT NULL,        -- path to log file in workspace
    timestamp TIMESTAMP NOT NULL
);

-- Historical stats (never pruned — survives run purges)
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

### Notes

- `node_executions` has both `attempt` (retry) and `iteration` (loop cycle). A loop iteration 5 could itself retry 3 times — these are tracked independently.
- Log content is written to files in the workspace `logs/` directory. The `logs` table stores file paths, not content. This avoids large TEXT blobs in SQLite for long-running agents.
- The `stats` table is never pruned. It captures a summary row when each run completes, so historical metrics survive `orc purge`.

---

## 7. Workspace Management

Each workflow run gets a directory under the project:

```
.orc/workspaces/<run-id>/
├── workspace/    # cloned repos, generated files
├── artifacts/    # outputs agents produce
└── logs/         # stdout/stderr files per node per attempt
```

The path is tracked in SQLite. `{{workspace}}` is a built-in template variable available in all nodes, pointing to the `workspace/` subdirectory.

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
- **`continue`** — marks the node as `failed` but the workflow continues. Downstream nodes can check `{{node_id.status}}` to detect the failure and branch accordingly.

### Timeout

If a node exceeds `timeout_seconds`, the process is killed and treated as a failure. Retries apply if configured.

All stdout/stderr from every invocation is logged to files regardless of outcome.

---

## 9. Concurrency Configuration

```yaml
# .orc/config.yml
concurrency:
  max_parallel_nodes: 4    # default: number of CPU cores
```

Overridable via CLI flags: `orc start workflow.yml --max-parallel-nodes 1`.

---

## 10. Storage & Retention

### Database and workspace location

SQLite database at `.orc/orc.db`. Workspaces at `.orc/workspaces/<run-id>/`. Everything is project-scoped.

### Auto-retention

```yaml
# .orc/config.yml
storage:
  retention_days: 30               # auto-purge runs older than this
  retention_policy: completed_only # completed_only (default), all, none
```

Purge check runs on startup — lightweight query before any command executes. The `stats` table is never affected by auto-retention or manual purge.

### Manual purge

`orc purge [--older-than 30d] [--status completed|failed|all]` deletes matching runs, their logs, and their workspace folders. Stats rows are preserved.

---

## 11. CLI Commands

```
orc init
    Creates .orc/ in the current directory with config.yml, orc.db,
    and workflows/ containing built-in workflow templates.

orc start <workflow.yml> [--input key=value]... [--max-parallel-nodes N]
    Starts a workflow run, prints the run ID.

orc list [--status running|completed|failed]
    Lists all runs with status and timestamps.

orc status <run-id>
    Shows run progress: each node's state, current loop iteration.
    For awaiting_input nodes: shows the message and how to respond.

orc attach <run-id> <node-id>
    Attaches to a session-based interactive node's tmux session.

orc respond <run-id> <node-id> <text or file path>
    Sends a response to a prompt-based interactive node.

orc logs <run-id> [--node <node-id>] [--attempt N] [--iteration N]
    Prints captured logs from the workspace log files.

orc cancel <run-id>
    Cancels a running workflow, kills active processes.

orc cleanup <run-id>
    Manually removes the workspace for a completed/failed run.

orc purge [--older-than 30d] [--status completed|failed|all]
    Deletes old runs, their logs, and workspace folders. Preserves stats.

orc stats
    Reports: DB path and size, total runs by status, active workspace
    count and disk usage, historical run counts, config summary.

orc config
    Lists all current config values.

orc config <key>
    Gets a specific config value.

orc config <key> <value>
    Sets a config value. Keys use dot notation:
    orc config concurrency.max_parallel_nodes 4

orc config --unset <key>
    Removes a config value, reverts to default.
```

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

Built-in workflows are bundled as resources in the Swift package. `orc init` copies them into `.orc/workflows/`. At runtime, the CLI looks for workflows only in the path provided to `orc start` — there is no implicit search in `.orc/workflows/`.

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
- **Additional providers** — the `cli-agent` configuration model allows adding new AI providers without code changes. Custom Swift providers can be added by implementing the `AgentProvider` protocol.
