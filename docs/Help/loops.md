# Loops

Loops let a node repeat until an evaluator condition is satisfied or a maximum iteration count is reached.

## Configuration

```yaml
- id: review
  agent: claude-code
  prompt: "Review the code and fix any issues."
  output: review_result
  loop:
    until: approved
    max_iterations: 10
    fresh_context: true
    prompt: |
      The previous review found issues. Re-review the code.
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `until` | string | yes | -- | Evaluator name to check after each iteration |
| `max_iterations` | int | no | `10` | Maximum iterations before the node fails |
| `fresh_context` | bool | no | `false` | Each iteration runs as a fresh process |
| `prompt` | string | no | -- | Override prompt for iterations 2 and beyond |

The node-level `prompt` is used for iteration 1. If `loop.prompt` is set, it replaces the node prompt for subsequent iterations.

## Evaluators

### Built-in Evaluators

**`approved`** -- Returns true when the node output matches `yes`, `y`, `approve`, or `approved` (case-insensitive, trimmed).

**`output_unchanged`** -- Returns true if the current iteration's output is identical to the previous iteration's output. Always returns false on the first iteration.

### Custom Evaluators

Place evaluator definitions in `.orc/evaluators/`:

**AI evaluator** -- asks an agent to judge the output:

```yaml
# .orc/evaluators/all-tasks-complete.yml
name: all_tasks_complete
type: ai
agent: claude-code
prompt: |
  Given this output:
  {{last_output}}

  Are all tasks complete? Answer YES or NO.
```

**Script evaluator** -- runs a shell command; exit code 0 means true:

```yaml
# .orc/evaluators/tests-pass.yml
name: tests_pass
type: script
command: "cd {{workspace}} && swift test"
```

Script evaluators also receive the last output via the `ORC_LAST_OUTPUT` environment variable.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | no | Evaluator name (defaults to filename) |
| `type` | string | yes | `ai`, `script`, or `workflow` |
| `agent` | string | for `ai` | Provider name |
| `prompt` | string | for `ai` | Template string (use `{{last_output}}`) |
| `command` | string | for `script` | Shell command to execute |

## How It Works

1. **Iteration 1**: The node executes with its top-level `prompt`.
2. The evaluator runs against the output.
3. If the evaluator returns true, the loop exits with the last output.
4. If not, `{{last_output}}` is updated and the next iteration begins, using `loop.prompt` if provided.
5. If `max_iterations` is exhausted, the node fails.

## Example: Review-Fix Loop

```yaml
nodes:
  - id: review
    agent: claude-code
    prompt: |
      Review the code for bugs and style issues.
      Output APPROVED if everything looks good, or NEEDS_WORK with details.
    output: review_result
    loop:
      until: approved
      max_iterations: 5
      fresh_context: true
      prompt: |
        Previous fixes were applied. Re-review the code.
        Output APPROVED if clean, or NEEDS_WORK with remaining issues.

  - id: fix
    agent: claude-code
    depends_on: review
    when: "{{review_result}} != 'APPROVED'"
    prompt: "Fix the issues found: {{review_result}}"
```
