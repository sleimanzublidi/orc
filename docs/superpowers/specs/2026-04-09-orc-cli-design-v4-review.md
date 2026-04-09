# Orc CLI Design Spec v4 — Review

## v3 Review Resolution

All 13 issues and 5 minor issues from the v3 review have been addressed:

- `review_approved` undefined → example now uses `approved`, loop removed from `review` node
- Node output capture → new §2 defines output per provider type
- `exit_code_zero` underspecified → removed from built-ins
- Evaluator failure handling → new subsection in §5
- No conditional branching → new §3 with `when:` guards and expression syntax
- Retry/failure interaction → §12 now explicit: "retries exhaust first"
- Skip cascading with multi-parent → both §3 and §12 define the same rule
- Nested workflow gaps → new §4 with workspace sharing and failure semantics
- Template escaping → `\{{` documented in §1
- Resume with modified config → §8 explicitly states ID-only matching
- Loop iteration ordering → explicitly sequential in §1 and §7
- `orc respond` to non-waiting node → error message defined in §7.4
- DB migration → `schema_version` table added to schema
- Config precedence → stated in §16
- Retention policy mismatch → aligned
- WAL mode timing → "at database creation time (`orc init`)"
- Nanoid → "Swift's random alphanumeric character generation (no external dependency)"
- Per-node timing in stats → added to `orc stats` output

---

## New Issues in v4

### 1. `on_failure: continue` doesn't satisfy downstream dependencies

This is the most significant gap. §12 defines three failure strategies, and §3/§12 share a dependency rule: "a node runs if at least one dependency completed; it is skipped only if all dependencies were skipped."

The problem: if node A has `on_failure: continue` and fails, its status is `failed` — not `completed`, not `skipped`. If node B depends only on node A, the rule says B runs only if a dependency "completed." Failed isn't completed. B doesn't match the skip rule either (A isn't skipped). B is in limbo.

The intent of `continue` is clearly that downstream work proceeds. The dependency satisfaction rule needs to account for this. Suggestion: "a dependency is satisfied if the node completed, or failed with `on_failure: continue`. A node is skipped only if all dependencies were skipped."

### 2. Escaped braces in YAML comment (line 26)

```yaml
output: plan_file              # alias: \{{plan_file}} = \{{plan.output}}
```

The `\{{` escape syntax is for the template engine, but YAML comments aren't processed by the template engine. This should use plain `{{plan_file}}` since it's documentation for the reader. Using the escape syntax in a comment implies it's needed there too.

### 3. `orc validate` template variable wording

Line 639 says "template variable resolution against declared inputs." This implies only input variables like `{{repo_path}}` are validated, not node output references like `{{plan.output}}` or status references like `{{lint.status}}`. The validation should also check that referenced node IDs exist in the workflow and are upstream dependencies. The wording should reflect this — something like "template variable resolution (inputs, node outputs, node statuses)."

### 4. Missing `orc version` command

Standard expectation for any CLI tool. Worth adding to the command list.

### 5. `when:` string literal escaping

The expression syntax defines single-quoted string literals (`'completed'`, `'yes'`), but doesn't define how to escape a single quote within a literal. Edge case for v1, but documenting `\'` or `''` avoids ambiguity.
