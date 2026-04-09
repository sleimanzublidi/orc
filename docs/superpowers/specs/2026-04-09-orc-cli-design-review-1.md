# Orc CLI Design Spec — Review 1

## Correctness / Gaps

**1. `github-copilot` provider is not viable as described (§5)**
`gh copilot suggest` is interactive-only — there's no headless/JSON mode. The spec acknowledges this with "(or equivalent headless mode)" but that mode doesn't exist. Either drop this provider from v1 or replace it with something that actually has a CLI API (e.g., `codex`, `aider`, or a generic `cli-agent` provider that wraps any command).

**2. Evaluator input is underspecified (§2)**
The evaluator table says evaluators "receive input (typically the last node output)" — but how? AI evaluators get a `prompt` but no explicit `input` field. Script evaluators have no mechanism to receive the node output (env var? stdin? template variable?). Define the contract: what data is passed, and how.

**3. `output` field on nodes is inconsistent (§1)**
`plan` node has `output: plan_file` — this looks like it names the output variable. But `implement` node (a loop) has no `output` field. Is the output auto-named as `{{node_id.output}}`? Is `plan_file` an alias? The relationship between `output:` on a node and the `{{node_id.output}}` template syntax needs to be explicit.

**4. Loop node output semantics (§4.4)**
For loop nodes, what is the "output"? The last iteration's output? An aggregation? This matters for downstream nodes that `depends_on` a loop node.

**5. `approved` evaluator is referenced but never defined (§1)**
The `approve` node uses `until: approved` — this isn't listed in built-in evaluators (§2) and no definition is shown. If it's a convention for interactive nodes, say so. If it requires a custom evaluator, show one.

**6. No schema for nested workflows (§1)**
Nested workflows are mentioned as a key concept but there's no example of how inputs are passed to the child workflow or how its output maps back. Add a node example:
```yaml
- id: sub
  workflow: path/to/other.yml
  inputs:
    repo_path: "{{repo_path}}"
  output: sub_result
```

## Design Concerns

**7. `max_parallel_nodes` vs `max_parallel_agents` (§9)**
The distinction is unclear. Nodes *are* agent invocations (mostly). When would you want these to differ? If the intent is that `max_parallel_agents` limits only AI-provider nodes while `max_parallel_nodes` limits all nodes (including `shell`), say that explicitly. Otherwise, collapse to one setting.

**8. Workspace at `/tmp/orc/` is fragile (§7)**
`/tmp` is cleared on reboot on macOS. For `cleanup: never` runs, the workspace will vanish unexpectedly. Consider defaulting to `.orc/workspaces/<run-id>/` or `~/.orc/workspaces/` instead.

**9. Database at `.orc/orc.db` is project-scoped (§10), but workspaces are at `/tmp` (§7)**
This split means a project's DB references paths that don't live under the project. If the DB is project-scoped, workspaces probably should be too — or the DB should be global (`~/.orc/`).

**10. Stats table duplicates `runs` data (§6)**
`stats` stores `run_id`, `workflow_name`, `status`, `node_count`, `duration_seconds`, `completed_at` — all derivable from `runs` + `node_executions`. A view or query is simpler and avoids staleness. Unless you need stats to survive run purges, in which case say so.

**11. `on_failure: continue` with empty output is surprising (§8)**
Downstream nodes run with "the failed node's output as empty" — this is a silent-failure footgun. Downstream nodes have no way to know the upstream failed. Consider injecting a `{{node_id.status}}` variable so downstream nodes can branch.

## Minor Issues

**12.** The `loop` field appears at two levels in the example — both as a property of `implement` and `approve`. But `approve` has no `agent` field. What runs the prompt? Implicit default provider?

**13.** `node_executions` has `attempt INTEGER` for retries but no foreign key for loop iterations. Loop iterations and retry attempts are different concepts — a loop iteration 5 could itself retry 3 times. Consider adding `iteration INTEGER`.

**14.** The `logs` table stores content as TEXT blobs. For long-running agents, this could mean very large rows. Consider whether streaming logs to files (already in `logs/` directory per §7) and storing only file paths in SQLite would be better.

**15.** `orc init` creates `workflows/` with built-in templates (§12), and the release archive also bundles `workflows/` (§13). No mention of how the CLI finds built-in workflows at runtime — does it look in the install path, or only in `.orc/workflows/`?

## What's Good

- Clean separation of OrcEngine as a library with the CLI as a thin client — this is the right call for the web server goal.
- The DAG-based execution with `depends_on` is straightforward and the right model.
- SQLite with WAL mode is a pragmatic choice for concurrent access.
- The evaluator abstraction is flexible (AI / script / workflow).
- Error handling strategies (`stop`/`skip`/`continue`) cover the right cases.
- Template syntax is simple and sufficient.

## Priority

The biggest items to resolve before implementation are **#1** (copilot provider viability), **#2** (evaluator input contract), **#3-4** (output naming/semantics), and **#8-9** (workspace location consistency).
