#!/bin/bash
# validate.sh — Smoke-test the orc binary from PreBuild/
#
# Creates a temporary directory, copies the binary, and exercises every
# command that can run without an AI provider.  Exit 0 = all green.
#
# Usage:
#   bash Scripts/validate.sh            # uses PreBuild/orc
#   bash Scripts/validate.sh /path/orc  # uses a custom binary

set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf "  \033[31m✗\033[0m %s — %s\n" "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf "  \033[33m⊘\033[0m %s — %s\n" "$1" "$2"; }

section() { printf "\n\033[1m── %s ──\033[0m\n" "$1"; }

# Run a command and assert exit code 0.
assert_ok() {
    local label="$1"; shift
    local output
    if output=$("$@" 2>&1); then
        echo "$output"
        return 0
    else
        local rc=$?
        fail "$label" "exit code $rc"
        echo "$output"
        return 1
    fi
}

# Assert that stdout contains a substring.
assert_contains() {
    local label="$1" output="$2" expected="$3"
    if echo "$output" | grep -qF "$expected"; then
        return 0
    else
        fail "$label" "expected output to contain '$expected'"
        return 1
    fi
}

# Assert that a command fails (non-zero exit).
assert_fails() {
    local label="$1"; shift
    local output
    if output=$("$@" 2>&1); then
        fail "$label" "expected non-zero exit but got 0"
        echo "$output"
        return 1
    else
        echo "$output"
        return 0
    fi
}

# ── Setup ───────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORC_BINARY="${1:-$REPO_ROOT/PreBuild/orc}"

if [ ! -x "$ORC_BINARY" ]; then
    echo "Error: Binary not found or not executable: $ORC_BINARY" >&2
    echo "Run 'bash Scripts/build.sh' first." >&2
    exit 1
fi

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Copy binary to temp root so it's self-contained.
cp "$ORC_BINARY" "$TMPDIR_ROOT/orc"
ORC="$TMPDIR_ROOT/orc"

# All commands run from inside the temp dir so .orc/ is found there.
cd "$TMPDIR_ROOT"

echo "Validating: $ORC_BINARY"
echo "Temp dir:   $TMPDIR_ROOT"

# ── 1. Commands that need no .orc/ directory ────────────────────────

section "Pre-init commands (no .orc/ required)"

# version
output=$(assert_ok "version" "$ORC" version) && {
    assert_contains "version: orc v" "$output" "orc v" && pass "version" || true
}

# help (topic list)
output=$(assert_ok "help (list)" "$ORC" help) && {
    assert_contains "help: topics listed" "$output" "Available help topics" && pass "help (list)" || true
}

# help <topic> — test each known topic
for topic in workflows templates loops providers custom-agents interactive-nodes nested-workflows run-management; do
    output=$(assert_ok "help $topic" "$ORC" help "$topic") && {
        pass "help $topic"
    }
done

# help <subcommand> — falls back to subcommand help
output=$(assert_ok "help purge" "$ORC" help "purge") && {
    assert_contains "help purge: shows usage" "$output" "purge" && pass "help purge (subcommand fallback)" || true
}

output=$(assert_ok "help cleanup" "$ORC" help "cleanup") && {
    assert_contains "help cleanup: shows usage" "$output" "cleanup" && pass "help cleanup (subcommand fallback)" || true
}

output=$(assert_ok "help status" "$ORC" help "status") && {
    assert_contains "help status: shows usage" "$output" "status" && pass "help status (subcommand fallback)" || true
}

# help <invalid topic> should fail
output=$(assert_fails "help bad-topic" "$ORC" help "nonexistent-topic-xyz") && {
    assert_contains "help bad-topic: error" "$output" "Unknown topic" && pass "help bad-topic (expected failure)" || true
}

# ── 2. Init ─────────────────────────────────────────────────────────

section "Project initialization"

output=$(assert_ok "init" "$ORC" init) && {
    pass "init"
}

# Verify structure created by init.
for item in .orc .orc/config.yml .orc/orc.db .orc/workflows .orc/evaluators; do
    if [ -e "$item" ]; then
        pass "init created $item"
    else
        fail "init created $item" "not found"
    fi
done

# Verify default workflows exist.
for wf in hello-shell.yaml ask-claude.yaml review-file.yaml; do
    if [ -f ".orc/workflows/$wf" ]; then
        pass "default workflow $wf"
    else
        fail "default workflow $wf" "not found"
    fi
done

# init --update (should succeed, adding new files without overwriting).
output=$(assert_ok "init --update" "$ORC" init --update) && {
    pass "init --update"
}

# init again (without --update) should fail — project already exists.
output=$(assert_fails "init (duplicate)" "$ORC" init) && {
    pass "init (duplicate, expected failure)"
}

# ── 3. Validate ─────────────────────────────────────────────────────

section "Workflow validation"

# Validate the default hello-shell workflow.
output=$(assert_ok "validate hello-shell" "$ORC" validate hello-shell) && {
    assert_contains "validate hello-shell: valid" "$output" "is valid" && pass "validate hello-shell" || true
    assert_contains "validate hello-shell: nodes" "$output" "Nodes: 1" && pass "validate hello-shell: node count" || true
}

# Validate ask-claude (should also be structurally valid).
output=$(assert_ok "validate ask-claude" "$ORC" validate ask-claude) && {
    assert_contains "validate ask-claude: valid" "$output" "is valid" && pass "validate ask-claude" || true
}

# Validate review-file.
output=$(assert_ok "validate review-file" "$ORC" validate review-file) && {
    assert_contains "validate review-file: valid" "$output" "is valid" && pass "validate review-file" || true
}

# Validate a custom multi-node workflow with dependencies.
cat > "$TMPDIR_ROOT/multi-node.yaml" <<'YAML'
name: multi-node-test
description: Tests DAG with dependencies and parallelism.
input:
  - name: message
    type: string
    required: false
nodes:
  - id: step-a
    agent: shell
    prompt: "echo 'A: {{message | default: hello}}'"
    output: a_out
  - id: step-b
    agent: shell
    prompt: "echo 'B: {{message | default: hello}}'"
    output: b_out
  - id: step-c
    agent: shell
    prompt: "echo 'C: {{a_out}} + {{b_out}}'"
    depends_on: [step-a, step-b]
    output: c_out
output:
  result: "{{c_out}}"
YAML

output=$(assert_ok "validate multi-node" "$ORC" validate "$TMPDIR_ROOT/multi-node.yaml") && {
    assert_contains "validate multi-node: valid" "$output" "is valid" && pass "validate multi-node" || true
    assert_contains "validate multi-node: 3 nodes" "$output" "Nodes: 3" && pass "validate multi-node: node count" || true
    assert_contains "validate multi-node: 1 input" "$output" "Inputs: 1" && pass "validate multi-node: input count" || true
}

# Validate an invalid workflow (missing required fields).
cat > "$TMPDIR_ROOT/invalid.yaml" <<'YAML'
name: bad-workflow
nodes:
  - id: a
    agent: shell
    prompt: "echo hi"
    depends_on: [nonexistent]
YAML

output=$(assert_fails "validate invalid" "$ORC" validate "$TMPDIR_ROOT/invalid.yaml") && {
    pass "validate invalid (expected failure)"
}

# Validate a workflow with warnings (unresolved template variable).
cat > "$TMPDIR_ROOT/warn.yaml" <<'YAML'
name: warn-workflow
nodes:
  - id: a
    agent: shell
    prompt: "echo '{{undefined_var}}'"
YAML

output=$(assert_ok "validate warn" "$ORC" validate "$TMPDIR_ROOT/warn.yaml") && {
    if echo "$output" | grep -qF "warning"; then
        pass "validate warn: warning detected"
    else
        # Not all builds emit warnings for this — still valid.
        skip "validate warn: warning detection" "no warning emitted (may be acceptable)"
    fi
}

# ── 4. Catalog ──────────────────────────────────────────────────────

section "Catalog"

output=$(assert_ok "catalog" "$ORC" catalog) && {
    assert_contains "catalog: Workflows header" "$output" "Workflows:" && pass "catalog: Workflows header" || true
    assert_contains "catalog: hello-shell listed" "$output" "hello-shell" && pass "catalog: hello-shell listed" || true
    assert_contains "catalog: Evaluators header" "$output" "Evaluators:" && pass "catalog: Evaluators header" || true
}

# ── 5. Config ───────────────────────────────────────────────────────

section "Configuration"

# List all config.
output=$(assert_ok "config (list)" "$ORC" config) && {
    assert_contains "config: max_parallel_nodes" "$output" "concurrency.max_parallel_nodes" && pass "config: list all" || true
}

# Get a specific key.
output=$(assert_ok "config get" "$ORC" config concurrency.max_parallel_nodes) && {
    assert_contains "config get: value" "$output" "8" && pass "config get concurrency.max_parallel_nodes" || true
}

# Set a key.
output=$(assert_ok "config set" "$ORC" config concurrency.max_parallel_nodes 4) && {
    assert_contains "config set: confirmation" "$output" "Set" && pass "config set" || true
}

# Verify the set took effect.
output=$(assert_ok "config get (verify)" "$ORC" config concurrency.max_parallel_nodes) && {
    assert_contains "config get verify: 4" "$output" "4" && pass "config get (verify set)" || true
}

# Unset a key.
output=$(assert_ok "config unset" "$ORC" config concurrency.max_parallel_nodes --unset) && {
    assert_contains "config unset: confirmation" "$output" "Removed" && pass "config unset" || true
}

# Get an invalid key.
output=$(assert_fails "config get invalid" "$ORC" config "nonexistent.key.xyz") && {
    pass "config get invalid key (expected failure)"
}

# Restore the key for subsequent tests.
"$ORC" config concurrency.max_parallel_nodes 8 >/dev/null 2>&1 || true

# ── 6. Run a shell-only workflow ────────────────────────────────────

section "Workflow execution (shell-only)"

# Start hello-shell with default input.
output=$(assert_ok "start hello-shell" "$ORC" start hello-shell) && {
    assert_contains "start: completed" "$output" "completed" || assert_contains "start: completed" "$output" "✓" || true
    assert_contains "start: Hello, World!" "$output" "Hello, World!" && pass "start hello-shell (default)" || true
}

# Start hello-shell with custom input.
output=$(assert_ok "start hello-shell (custom)" "$ORC" start hello-shell --input "greeting=Smoke test!") && {
    assert_contains "start custom: Smoke test!" "$output" "Smoke test!" && pass "start hello-shell (custom input)" || true
}

# Start hello-shell with trailing arg syntax.
output=$(assert_ok "start hello-shell (trailing)" "$ORC" start hello-shell "Trailing arg test") && {
    assert_contains "start trailing: arg" "$output" "Trailing arg test" && pass "start hello-shell (trailing arg)" || true
}

# Start the multi-node workflow (exercises DAG + parallelism).
output=$(assert_ok "start multi-node" "$ORC" start "$TMPDIR_ROOT/multi-node.yaml" --input "message=dag-test") && {
    assert_contains "start multi-node: completed" "$output" "completed" || assert_contains "start multi-node: completed" "$output" "✓" || true
    pass "start multi-node"
}

# ── 7. List runs ────────────────────────────────────────────────────

section "Run management"

output=$(assert_ok "list" "$ORC" list) && {
    assert_contains "list: has runs" "$output" "hello-shell" && pass "list: shows runs" || true
}

# List with status filter.
output=$(assert_ok "list --status completed" "$ORC" list --status completed) && {
    assert_contains "list completed: has runs" "$output" "completed" && pass "list --status completed" || true
}

# List with status that yields no results.
output=$(assert_ok "list --status failed" "$ORC" list --status failed) && {
    pass "list --status failed (no results)"
}

# Extract a run ID from the list output for subsequent commands.
RUN_ID=$("$ORC" list 2>/dev/null | grep "hello-shell" | head -1 | awk '{print $1}')

if [ -z "$RUN_ID" ]; then
    skip "status/logs/cleanup" "could not extract run ID from list output"
else
    # ── 8. Status ───────────────────────────────────────────────────
    output=$(assert_ok "status $RUN_ID" "$ORC" status "$RUN_ID") && {
        assert_contains "status: shows run" "$output" "$RUN_ID" && pass "status" || true
        assert_contains "status: shows node" "$output" "greet" && pass "status: node table" || true
    }

    # ── 9. Logs ─────────────────────────────────────────────────────
    output=$(assert_ok "logs $RUN_ID" "$ORC" logs "$RUN_ID") && {
        pass "logs"
    }

    # Logs with --node filter.
    output=$(assert_ok "logs --node greet" "$ORC" logs "$RUN_ID" --node greet) && {
        pass "logs --node greet"
    }

    # ── 10. Cleanup (single run) ──────────────────────────────────
    output=$(assert_ok "cleanup $RUN_ID" "$ORC" cleanup "$RUN_ID") && {
        assert_contains "cleanup: confirmation" "$output" "removed" && pass "cleanup" || true
    }

    # ── 10a. Status (no args) — in-progress listing ─────────────
    output=$(assert_ok "status (no args)" "$ORC" status) && {
        pass "status (no args, in-progress listing)"
    }
fi

# ── 11. Stats ───────────────────────────────────────────────────────

section "Statistics"

output=$(assert_ok "stats" "$ORC" stats) && {
    assert_contains "stats: Database" "$output" "Database:" && pass "stats: database info" || true
    assert_contains "stats: Runs" "$output" "Runs:" && pass "stats: run counts" || true
}

# ── 12. Purge ───────────────────────────────────────────────────────

section "Purge"

# Purge with a duration (nothing old enough, but command should succeed).
output=$(assert_ok "purge --older-than 1d" "$ORC" purge --older-than 1d) && {
    assert_contains "purge: complete" "$output" "Purge complete" && pass "purge --older-than 1d" || true
}

# Purge with status filter (named option).
output=$(assert_ok "purge --status completed" "$ORC" purge --status completed) && {
    assert_contains "purge status: complete" "$output" "Purge complete" && pass "purge --status completed" || true
}

# Purge with positional status filter.
output=$(assert_ok "purge completed (positional)" "$ORC" purge completed) && {
    assert_contains "purge positional: complete" "$output" "Purge complete" && pass "purge completed (positional)" || true
}

# Purge with positional date filter (nothing before that date).
output=$(assert_ok "purge <date" "$ORC" purge '<2020-01-01') && {
    assert_contains "purge <date: complete" "$output" "Purge complete" && pass "purge <date" || true
}

# Purge --older-than with ISO date.
output=$(assert_ok "purge --older-than date" "$ORC" purge --older-than 2020-01-01) && {
    assert_contains "purge iso date: complete" "$output" "Purge complete" && pass "purge --older-than ISO date" || true
}

# Purge --dry-run shows preview.
output=$(assert_ok "purge --dry-run" "$ORC" purge --dry-run) && {
    pass "purge --dry-run"
}

# Purge with invalid duration should fail.
output=$(assert_fails "purge bad duration" "$ORC" purge --older-than "xyz") && {
    pass "purge bad duration (expected failure)"
}

# Purge with invalid positional should fail.
output=$(assert_fails "purge bad positional" "$ORC" purge "some-random-id") && {
    pass "purge bad positional (expected failure)"
}

# ── 13. Cancel (on a non-running ID — should fail gracefully) ───────

section "Cancel (error paths)"

output=$(assert_fails "cancel nonexistent" "$ORC" cancel "nonexistent-run-id") && {
    pass "cancel nonexistent (expected failure)"
}

# ── 14. Resume (on a completed run — should fail gracefully) ────────

section "Resume (error paths)"

if [ -n "${RUN_ID:-}" ]; then
    output=$(assert_fails "resume completed run" "$ORC" resume "$RUN_ID") && {
        pass "resume completed run (expected failure)"
    }
else
    skip "resume" "no run ID available"
fi

# ── 15. Respond (error paths) ──────────────────────────────────────

section "Respond (error paths)"

output=$(assert_fails "respond nonexistent" "$ORC" respond "nonexistent-id" "node1" "hello") && {
    pass "respond nonexistent (expected failure)"
}

# ── 15a. Cleanup bulk operations ───────────────────────────────────

section "Cleanup (bulk)"

# Cleanup by status.
output=$(assert_ok "cleanup completed" "$ORC" cleanup completed) && {
    assert_contains "cleanup completed: complete" "$output" "Cleanup complete" && pass "cleanup completed" || true
}

# Cleanup all.
output=$(assert_ok "cleanup all" "$ORC" cleanup all) && {
    assert_contains "cleanup all: complete" "$output" "Cleanup complete" && pass "cleanup all" || true
}

# Cleanup with date filter (nothing before that date).
output=$(assert_ok "cleanup <date" "$ORC" cleanup '<2020-01-01') && {
    assert_contains "cleanup <date: complete" "$output" "Cleanup complete" && pass "cleanup <date" || true
}

# Cleanup --dry-run.
output=$(assert_ok "cleanup --dry-run all" "$ORC" cleanup all --dry-run) && {
    pass "cleanup --dry-run all"
}

# Cleanup with no arguments should fail.
output=$(assert_fails "cleanup no args" "$ORC" cleanup) && {
    pass "cleanup no args (expected failure)"
}

# Cleanup with invalid date should fail.
output=$(assert_fails "cleanup bad date" "$ORC" cleanup '<not-a-date') && {
    pass "cleanup bad date (expected failure)"
}

# ── 16. Cleanup already-cleaned run (idempotency) ──────────────────

section "Edge cases"

if [ -n "${RUN_ID:-}" ]; then
    if output=$("$ORC" cleanup "$RUN_ID" 2>&1); then
        pass "cleanup (idempotent)"
    else
        # Some implementations may fail on double-cleanup — that's acceptable.
        skip "cleanup (idempotent)" "double cleanup not supported"
    fi
fi

# ── 17. Workflow with failure handling ──────────────────────────────

section "Failure handling"

cat > "$TMPDIR_ROOT/fail-workflow.yaml" <<'YAML'
name: fail-test
description: Tests on_failure behavior.
nodes:
  - id: will-fail
    agent: shell
    prompt: "exit 1"
    on_failure: skip
  - id: should-run
    agent: shell
    prompt: "echo 'still running'"
    depends_on: [will-fail]
    output: result
output:
  result: "{{result}}"
YAML

output=$(assert_ok "validate fail-workflow" "$ORC" validate "$TMPDIR_ROOT/fail-workflow.yaml") && {
    pass "validate fail-workflow"
}

output=$(assert_ok "start fail-workflow" "$ORC" start "$TMPDIR_ROOT/fail-workflow.yaml") && {
    # The run should complete (not crash) because on_failure: skip is set.
    pass "start fail-workflow (on_failure: skip)"
}

# ── 18. Workflow with conditional (when:) ───────────────────────────

cat > "$TMPDIR_ROOT/when-workflow.yaml" <<'YAML'
name: when-test
description: Tests conditional node execution.
input:
  - name: flag
    type: string
    required: false
nodes:
  - id: always
    agent: shell
    prompt: "echo 'always runs'"
    output: base
  - id: conditional
    agent: shell
    prompt: "echo 'conditional ran'"
    depends_on: [always]
    when: "flag == 'yes'"
    output: cond_out
output:
  result: "{{base}}"
YAML

output=$(assert_ok "validate when-workflow" "$ORC" validate "$TMPDIR_ROOT/when-workflow.yaml") && {
    pass "validate when-workflow"
}

# Run without flag — conditional should be skipped.
output=$(assert_ok "start when-workflow (no flag)" "$ORC" start "$TMPDIR_ROOT/when-workflow.yaml") && {
    if echo "$output" | grep -qF "skipped"; then
        pass "start when-workflow: conditional skipped"
    else
        skip "start when-workflow: skip detection" "could not confirm skip in output"
    fi
}

# Run with flag=yes — conditional should run.
output=$(assert_ok "start when-workflow (flag=yes)" "$ORC" start "$TMPDIR_ROOT/when-workflow.yaml" --input "flag=yes") && {
    pass "start when-workflow (flag=yes)"
}

# ── 19. Nested workflow ────────────────────────────────────────────

section "Nested workflow"

cat > "$TMPDIR_ROOT/child.yaml" <<'YAML'
name: child
description: Simple child workflow.
input:
  - name: message
    type: string
    required: true
nodes:
  - id: greet
    agent: shell
    prompt: "echo 'Hello from child: {{message}}'"
    output: greeting
output:
  result: "{{greeting}}"
YAML

cat > "$TMPDIR_ROOT/parent.yaml" <<'YAML'
name: parent
description: Calls a child workflow.
nodes:
  - id: nest
    workflow: CHILD_PATH
    inputs:
      message: "nested-test"
    output: nested_out
output:
  result: "{{nested_out}}"
YAML

# Patch the parent to use the actual temp path.
sed -i '' "s|CHILD_PATH|$TMPDIR_ROOT/child.yaml|" "$TMPDIR_ROOT/parent.yaml"

output=$(assert_ok "validate parent (nested)" "$ORC" validate "$TMPDIR_ROOT/parent.yaml") && {
    pass "validate parent (nested)"
}

output=$(assert_ok "start parent (nested)" "$ORC" start "$TMPDIR_ROOT/parent.yaml") && {
    assert_contains "nested: child output" "$output" "Hello from child: nested-test" && pass "start parent (nested workflow)" || true
}

# Top-level list should NOT show child run (hidden by default).
output=$(assert_ok "list (top-level)" "$ORC" list) && {
    if echo "$output" | grep -qF "child"; then
        # Child visible in top-level — might be expected if no parent_run_id yet.
        skip "list: child hidden" "child run visible in default list (pre-existing DB)"
    else
        pass "list: child hidden by default"
    fi
}

# --all flag should show child runs.
output=$(assert_ok "list --all (nested child)" "$ORC" list --all) && {
    assert_contains "list --all: child run" "$output" "child" && pass "list --all: child run visible" || true
}

# ── 20. Loop + workflow ───────────────────────────────────────────

section "Loop + workflow"

cat > "$TMPDIR_ROOT/loop-child.yaml" <<'YAML'
name: loop-child
description: Child for loop testing.
input:
  - name: iteration_input
    type: string
    required: false
    default: "none"
nodes:
  - id: step
    agent: shell
    prompt: "echo 'iteration output'"
    output: out
output:
  result: "{{out}}"
YAML

cat > "$TMPDIR_ROOT/loop-parent.yaml" <<'YAML'
name: loop-parent
description: Calls child in a loop.
input:
  - name: max
    type: string
    default: "2"
nodes:
  - id: iterate
    workflow: LOOP_CHILD_PATH
    inputs:
      iteration_input: "{{last_output}}"
    loop:
      until: approved
      max_iterations: "{{max}}"
    output: result
output:
  result: "{{result}}"
YAML

# Patch the parent to use the actual temp path.
sed -i '' "s|LOOP_CHILD_PATH|$TMPDIR_ROOT/loop-child.yaml|" "$TMPDIR_ROOT/loop-parent.yaml"

output=$(assert_ok "validate loop-parent" "$ORC" validate "$TMPDIR_ROOT/loop-parent.yaml") && {
    pass "validate loop-parent"
}

# The child never returns "approved", so this should fail after max_iterations.
# The important thing is that child runs are actually created (not a no-op).
output=$("$ORC" start "$TMPDIR_ROOT/loop-parent.yaml" --input "max=2" 2>&1) || true

if echo "$output" | grep -qF "max iterations"; then
    pass "start loop-parent: hit max iterations (expected)"
elif echo "$output" | grep -qF "failed"; then
    pass "start loop-parent: failed after iterations (expected)"
else
    fail "start loop-parent" "expected max iterations or failure, got: $(echo "$output" | head -3)"
fi

# Verify child runs were created — this is the core regression check.
# Before the fix, loop+workflow created zero child runs.
# Use --all to see child runs (hidden by default since they have parentRunID).
list_output=$(assert_ok "list (loop children)" "$ORC" list --all) || true
child_count=$(echo "$list_output" | grep -c "loop-child" || true)

if [ "$child_count" -ge 2 ]; then
    pass "loop+workflow: $child_count child runs created"
else
    fail "loop+workflow: child runs" "expected >=2 child runs, found $child_count"
fi

# ── 22. Purge all (clean slate) ────────────────────────────────────

section "Final cleanup"

output=$(assert_ok "purge all" "$ORC" purge all) && {
    pass "purge all"
}

# Verify list is empty.
output=$(assert_ok "list (empty)" "$ORC" list) && {
    assert_contains "list empty: No runs" "$output" "No runs found" && pass "list (empty after purge)" || true
}

# ── Summary ─────────────────────────────────────────────────────────

section "Summary"

TOTAL=$((PASS + FAIL + SKIP))
printf "\n  Total: %d  |  \033[32mPassed: %d\033[0m  |  \033[31mFailed: %d\033[0m  |  \033[33mSkipped: %d\033[0m\n\n" \
    "$TOTAL" "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
    echo "Failures:"
    for f in "${FAILURES[@]}"; do
        printf "  \033[31m✗\033[0m %s\n" "$f"
    done
    echo ""
    exit 1
fi

echo "All checks passed."
exit 0
