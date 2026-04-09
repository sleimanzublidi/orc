# Orc CLI Design Spec v2 — Review

## V1 Review Resolution

All 15 items from review 1 are addressed in v2:

| # | Issue | Status |
|---|-------|--------|
| 1 | `github-copilot` provider not viable | **Fixed.** Replaced with generic `cli-agent` provider model. |
| 2 | Evaluator input contract underspecified | **Fixed.** §2 defines contract — `{{last_output}}` for AI, stdin + env var for script, input for workflow. |
| 3 | `output` field inconsistency | **Fixed.** `output:` is an alias; `{{node_id.output}}` always available. |
| 4 | Loop node output semantics | **Fixed.** Last iteration's output. |
| 5 | `approved` evaluator undefined | **Fixed.** Listed in built-in evaluators. |
| 6 | No nested workflow schema | **Fixed.** Example and explanation added. |
| 7 | `max_parallel_nodes` vs `max_parallel_agents` confusion | **Fixed.** Collapsed to single setting. |
| 8 | Workspace at `/tmp/` fragile | **Fixed.** Moved to `.orc/workspaces/<run-id>/`. |
| 9 | DB/workspace location split | **Fixed.** Both project-scoped under `.orc/`. |
| 10 | Stats table duplicates runs data | **Fixed.** Rationale explicit — stats survive purges. |
| 11 | `on_failure: continue` silent failure | **Fixed.** `{{node_id.status}}` available for downstream branching. |
| 12 | `approve` node has no agent | **Fixed.** `interactive: prompt` managed by engine, no agent needed. |
| 13 | No iteration tracking on `node_executions` | **Fixed.** `iteration` column added alongside `attempt`. |
| 14 | Logs as TEXT blobs | **Fixed.** Logs are files; table stores paths only. |
| 15 | Built-in workflow discovery at runtime | **Fixed.** Bundled as Swift resources, copied on init, CLI uses explicit path. |

## New Issues in v2

### Correctness / Gaps

**1. `interactive: session` + `loop` interaction is undefined**
The `review` node has `interactive: session` but no `loop`. The `approve` node has `interactive: prompt` with a `loop`. But what happens if you combine `interactive: session` with `loop`? The user attaches to tmux, the process exits, the evaluator runs — if false, does a new tmux session spawn? Does the user need to re-attach? This combo is likely needed in practice (e.g., iterative review sessions) and the behavior should be specified.

**2. `fresh_context: true` only makes sense for some providers**
For `claude-code`, spawning a new process clears conversation history — `fresh_context` is meaningful. For `shell`, every invocation is already stateless. For `interactive: session`, it's unclear — does it mean a new tmux session per iteration? The scope of this flag should be defined per provider type, or at least noted as provider-dependent.

**3. Evaluator resolution order is unspecified**
A `until:` field references an evaluator by name. The spec says evaluators are defined in YAML files and some are built-in. But where does the engine look? Is it `evaluators/` directory? `.orc/evaluators/`? What if a custom evaluator shadows a built-in name? Define the resolution order.

**4. `{{workspace}}` points to `workspace/` subdirectory, but `command:` in shell nodes uses `cd {{repo_path}}`**
In the example, the `lint` node does `cd {{repo_path}} && swift build`. But there's also `{{workspace}}` pointing to `.orc/workspaces/<run-id>/workspace/`. Are these the same? If `repo_path` is user-provided input (`.`) and `workspace` is the orc-managed directory, they're different things. The spec should clarify when agents operate in the user's repo vs. the orc workspace.

**5. No mechanism for node-to-node file passing**
Nodes pass data via `{{node_id.output}}` which is text (stored as `TEXT` in SQLite). But what if a node produces a file (e.g., `get-image` receives a file path via `orc respond`)? Is the output the file path as a string? The file content? This is especially relevant for the `orc respond <run-id> <node-id> <text or file path>` command — how does the engine distinguish text from a file path?

**6. No `orc resume` or restart capability**
If a run fails at node 8 of 10 and the user fixes the issue, there's no way to resume from the failure point. `orc start` creates a new run. For long workflows with expensive nodes, this is painful. At minimum, acknowledge this as a v1 limitation.

### Design Concerns

**7. `orc config` mutation model is implicit**
`orc config <key> <value>` modifies `.orc/config.yml`. But the config file is also shown with YAML structure (nested keys like `concurrency.max_parallel_nodes`). Does `orc config` do YAML-aware editing, or does it maintain a flat key-value store that gets serialized? YAML round-tripping (preserving comments, ordering) is a known pain point.

**8. Cleanup on `on_success` deletes debugging evidence**
The default `cleanup: on_success` removes the workspace on success. But "success" doesn't mean "correct" — a workflow might complete successfully with wrong output. Users debugging output quality will lose logs and artifacts. Consider whether the default should be `never` with auto-retention handling cleanup instead, or at minimum note this tradeoff.

**9. `orc cancel` semantics are thin**
"Kills active processes" — how? SIGTERM then SIGKILL after a grace period? What about tmux sessions for interactive nodes? What happens to nodes in `awaiting_input`? What's the final run status — `failed` or a distinct `cancelled`?

**10. No validation command**
There's no `orc validate <workflow.yml>` to check a workflow for errors (missing dependencies, circular deps, undefined evaluators, invalid template variables) without running it. This is a common DX expectation for YAML-based tools.

### Minor

**11.** The `get-image` node in the example has `interactive: prompt` with a `message` but no `depends_on`. This means it could fire immediately at workflow start — is that intentional? If so, it's a good example of a parallel prompt, but it's worth a callout since it's non-obvious.

**12.** `output_unchanged` built-in evaluator compares "current iteration output to previous" — but on the first iteration there is no previous. Does it return false (continue looping)? Specify the edge case.

**13.** The `AgentProvider` protocol has `execute` and `executeInteractive` — but `interactive: prompt` nodes don't use a provider at all. The protocol could benefit from a note that it only covers agent-backed nodes.

**14.** Run ID is described as "short UUID" — how short? UUIDs are 36 chars. If you mean a truncated hash or nanoid-style ID, specify the format and collision strategy.

## What's Improved

The v2 spec is significantly tighter than v1. The interactive model (session vs prompt) is well-separated, the evaluator contract is clear, the workspace/DB locality issue is resolved, and the provider abstraction is extensible without being over-engineered. The YAML example covers nearly every feature (loops, interactive, nested workflows, shell nodes) making the spec self-documenting.

## Priority

The biggest items before implementation: **#1** (session + loop), **#3** (evaluator resolution), **#4** (workspace vs repo_path), and **#5** (file passing). These will surface as ambiguities during implementation. **#6** (resume) and **#10** (validate) are DX items that can be deferred but should be acknowledged.
