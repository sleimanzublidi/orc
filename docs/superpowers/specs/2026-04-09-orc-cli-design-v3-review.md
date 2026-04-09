# Orc CLI Design Spec v3 — Review

## Issues

### 1. `review_approved` evaluator is undefined

The example workflow (line 52) uses `until: review_approved`, but the built-in evaluators in S2 only define `approved`, `exit_code_zero`, and `output_unchanged`. Either the example should use `approved`, or `review_approved` needs to be defined (as a built-in or as a custom evaluator in the example).

### 2. Node output capture semantics are unspecified

The spec never defines what constitutes a node's "output." For `claude-code` with `--output-format json`, it's presumably the JSON response. For `shell` — is it stdout? stderr? Both? Last line? Full stream? This matters because evaluators receive `{{last_output}}` and downstream nodes consume `{{node_id.output}}`.

### 3. `exit_code_zero` built-in evaluator is underspecified

It "runs a command, true if exit code is 0" — but what command? The node's own command? A separate one? The other built-ins (`approved`, `output_unchanged`) are self-contained; this one implies external input that isn't documented.

### 4. Evaluator failure handling is missing

What happens if an evaluator itself fails (AI agent crashes, script errors with a non-boolean exit)? Is it treated as "false" (loop continues)? Propagated as a node failure? This is a runtime scenario that needs a defined behavior.

### 5. No conditional branching at the workflow level

Nodes can check `{{node_id.status}}` in prompts, which works for AI agents that can reason about it. But shell nodes or sub-workflows have no way to conditionally execute based on upstream status. Consider whether a `when:` guard (e.g., `when: "{{lint.status}} == 'completed'"`) is needed, or explicitly state that conditional logic is out of scope for v1.

### 6. `on_failure` and `retry` interaction order is ambiguous

If a node has `max_attempts: 3` and `on_failure: skip`, does it retry 3 times before applying the skip strategy, or skip on first failure? The spec should state: retries exhaust first, then `on_failure` applies.

### 7. `on_failure: skip` cascading behavior with multi-parent nodes

The spec says downstream nodes of a skipped node are "also skipped." But what about a node that depends on two upstream nodes where only one was skipped? Is it skipped (any-skip-cascades), or does it run with `{{skipped_node.status}} == "skipped"` (only-if-all-skipped)?

### 8. Nested workflow semantics have gaps

- Does a child workflow get its own workspace, or share the parent's `{{workspace}}`?
- If a child workflow fails, does `retry` on the parent node re-run the entire child workflow?
- How does the child's internal node status map to the parent node's status?

### 9. Template variable escaping

No mention of how to produce a literal `{{` in a prompt. Users working with Jinja, Mustache, Go templates, or similar will hit this immediately. A common solution is `\{{` or `{{{raw}}}`.

### 10. Resume with modified node config

S5 validates that completed node IDs still exist in the re-parsed YAML, but what if a completed node's configuration changed (different prompt, different agent)? The spec should clarify that completed nodes are matched by ID only and their config changes are ignored (since they won't re-run).

### 11. Loop iterations are implicitly sequential

The spec says the executor "re-invokes the node's provider in a cycle," implying sequential iteration. This should be stated explicitly — concurrent loop iterations would have very different semantics.

### 12. `orc respond` to a non-waiting node

No defined behavior for running `orc respond` against a node that isn't in `awaiting_input`. Should error with a clear message.

### 13. Database migration strategy

No mention of schema versioning or migration for SQLite when upgrading Orc versions. For a persistent local database, this will matter by v1.1.

---

## Minor Issues

- **Config precedence**: CLI flags override config, but the general rule (CLI > config > defaults) is never stated.
- **`retention_policy` options mismatch**: `orc purge` accepts `completed|failed|cancelled|all`, but the config only lists `completed_only`, `all`, `none`. These should align.
- **WAL mode**: Mentioned as enabling concurrent access, but never stated when it's activated (init? first access?).
- **Nanoid**: "8-character alphanumeric nanoid" — clarify whether this is the nanoid library or just the ID format, since it implies a dependency.
- **`orc stats`**: Reports run-level duration but not per-node timing. Node-level durations are already in the schema (`started_at`/`completed_at` on `node_executions`) — worth surfacing in the command output.

---

## Strengths

- The functional model (input -> task -> output) with DAG-based parallelization is clean and easy to reason about.
- Two distinct interactive modes (`session` vs `prompt`) cover the real use cases well without overcomplicating the model.
- Resume with YAML re-parsing is pragmatic — lets users fix workflows before retrying.
- Provider abstraction with `cli-agent` config means new AI tools don't require code changes.
- Stats table surviving purges, log files instead of SQLite blobs, and workspace separation are all good operational choices.
- The OrcEngine/CLI split with web-server readiness as a constraint is forward-thinking without being speculative.
