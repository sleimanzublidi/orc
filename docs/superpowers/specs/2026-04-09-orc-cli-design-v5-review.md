# Orc CLI Design Spec v5 — Review

## v4 Review Resolution

All 5 issues from the v4 review have been addressed:

- `on_failure: continue` downstream dependencies — §3 (line 158) and §12 (lines 560-561) now define the unified dependency satisfaction rule: "a dependency is satisfied if it completed or failed with `on_failure: continue`."
- Escaped braces in YAML comment — line 26 now uses plain `{{plan_file}}`.
- `orc validate` template variable wording — lines 639-640 now say "inputs, node output references, node status references."
- Missing `orc version` command — added at lines 700-701.
- `when:` string literal escaping — line 132 documents `\'` for escaping single quotes.

## New Issues in v5

### 1. Broken cross-reference (line 94)

`(see §5.4)` references a section that doesn't exist. §5 is Evaluators. The session + loop execution behavior being referenced is in §7.4 (Execute). Should be `(see §7.4)`.

### 2. `depends_on` description uses "complete" loosely (line 89)

"list of node IDs that must complete before this node runs" — but the dependency satisfaction rule (§3, §12) is "completed or failed with `on_failure: continue`." The word "complete" here is misleading. Consider "that must resolve" or "that must finish" to match the actual semantics.

### 3. §7.1 Parse wording inconsistency (line 306)

"Template variables are checked against declared inputs" still only mentions inputs. §16's `orc validate` was correctly updated to "inputs, node output references, node status references." The parse step description should match since it describes the same validation.
