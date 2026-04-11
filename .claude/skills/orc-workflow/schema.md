# Orc Workflow YAML Schema

Complete reference for all fields, types, and validation rules in Orc workflow YAML files.

## Top-Level Fields

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `name` | String | Yes | — | Must be non-empty |
| `description` | String | No | nil | Free text |
| `input` | [Input] | No | [] | Input parameter declarations |
| `nodes` | [Node] | Yes | — | Must be non-empty |
| `output` | {String: String} | No | nil | Output mapping; values are template strings |
| `cleanup` | CleanupPolicy | No | `"30d"` | Workspace cleanup policy |

## Input Fields

| Field | Type | Required | Default |
|-------|------|----------|---------|
| `name` | String | Yes | — |
| `type` | String | No | `"string"` |
| `required` | Bool | No | `true` |

Known types: `string`, `file`, `bool`.

## Node Fields

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `id` | String | Yes | — | Unique, non-empty |
| `agent` | String | Conditional | nil | Required unless `command`, `workflow`, or `interactive: prompt` is set. Values: `claude-code`, `shell`, or custom agent name from config |
| `prompt` | String | No | nil | Template string sent to agent |
| `command` | String | No | nil | Shell command (used instead of `agent` for pure shell nodes) |
| `depends_on` | [String] or String | No | [] | Node IDs this node depends on. Accepts both array and single string |
| `output` | String | No | nil | Output alias — makes `{{alias}}` equivalent to `{{node_id.output}}`. Must not collide with other node IDs or input names |
| `when` | String | No | nil | Conditional guard expression (see Expression Syntax below) |
| `loop` | LoopConfig | No | nil | Repeating execution config |
| `interactive` | `"session"` or `"prompt"` | No | nil | Interactive mode |
| `message` | String | No | — | Message shown to user when `interactive: prompt`. Must be non-empty |
| `retry` | RetryConfig | No | nil | Retry-on-failure config |
| `timeout_seconds` | Int | No | nil | Max execution time in seconds |
| `on_failure` | `"stop"` / `"skip"` / `"continue"` | No | `"stop"` | Failure strategy |
| `workflow` | String | No | nil | Path to a nested workflow file. Mutually exclusive with `agent`/`command` |
| `inputs` | {String: String} | No | nil | Input mapping for nested workflow nodes. Required (non-empty) when `workflow` is set. Values are template strings |
| `workspace` | `"shared"` / `"isolated"` | No | `"shared"` | Workspace mode for nested workflows |

**Constraint:** A node must have at least one of: `agent`, `command`, `workflow`, or `interactive: prompt`.

## LoopConfig

| Field | Type | Required | Default |
|-------|------|----------|---------|
| `until` | String | Yes | — |
| `max_iterations` | Int | No | 10 |
| `fresh_context` | Bool | No | false |
| `prompt` | String | No | — |

If the node has no top-level `prompt`, `loop.prompt` is promoted to the node's prompt.

## RetryConfig

| Field | Type | Required | Default |
|-------|------|----------|---------|
| `max_attempts` | Int | No | 1 |
| `delay_seconds` | Int | No | 0 |

## CleanupPolicy

| Value | Behavior |
|-------|----------|
| `"30d"`, `"7d"`, etc. | Retained N days after run completes |
| `"on_success"` | Deleted on success; retained on failure |
| `"always"` | Deleted immediately (prevents `orc resume`) |
| `"never"` | Retained until manual `orc cleanup` |

## InteractiveMode

| Value | Behavior |
|-------|----------|
| `"session"` | Launches agent in tmux. Requires `agent` field |
| `"prompt"` | Pauses for user response. Requires non-empty `message`. Does not require `agent` |

## FailureStrategy

| Value | Behavior |
|-------|----------|
| `"stop"` | Run fails. No further nodes dispatched |
| `"skip"` | Node marked skipped. Downstream nodes skipped only if ALL their deps were skipped |
| `"continue"` | Node marked failed but workflow continues. Dependency considered satisfied |

## Template Syntax

| Syntax | Description |
|--------|-------------|
| `{{variable}}` | Resolved from inputs, node outputs, aliases, or builtins |
| `{{node_id.output}}` | Output of a specific node |
| `{{node_id.status}}` | Status of a specific node |
| `{{repo_root}}` | Repository root path (builtin) |
| `{{orc_root}}` | `.orc` directory path, i.e. `{{repo_root}}/.orc` (builtin) |
| `{{workspace}}` | Per-run workspace path for logs/artifacts (builtin) |
| `{{last_output}}` | Last output (builtin) |
| `{{var \| default: fallback}}` | Default filter — fallback used if variable is unresolved |
| `\{{` | Escape — produces literal `{{` in output |

Whitespace inside braces is trimmed: `{{ x }}` equals `{{x}}`.

### Resolution Order

1. Dot-qualified: `{{node_id.output}}` from outputs, `{{node_id.status}}` from statuses
2. Built-in `{{repo_root}}` from repository root
3. Built-in `{{orc_root}}` derived as `{{repo_root}}/.orc`
4. Built-in `{{workspace}}` from per-run workspace path
5. Built-in `{{last_output}}` from outputs
6. Input lookup by name
7. Output/alias lookup by name
8. Unresolved → error (unless `| default:` is present)

## Expression Syntax

Used in `when:` guards and `loop.until` evaluator names.

### Operators

| Operator | Meaning |
|----------|---------|
| `==` | String equality |
| `!=` | String inequality |
| `&&` | Logical AND |
| `\|\|` | Logical OR |
| `!` | Logical negation |
| `(`, `)` | Grouping |

**Precedence (low to high):** `\|\|` → `&&` → `!` → comparison/primary

### Values

- **String literals:** `'value'` with `\'` escape for embedded quotes
- **Bare values:** truthy if non-empty AND not `"false"`

### Node Status Values

`completed`, `failed`, `skipped`, `pending`, `running`, `awaiting_input`, `cancelled`

### Examples

```yaml
when: "{{tests.status}} == 'completed'"
when: "{{build.status}} == 'completed' && {{tests.status}} == 'completed'"
when: "{{deploy.status}} == 'failed'"
when: "{{approve.output}} != 'yes'"
when: "!({{a.status}} == 'failed')"
when: "({{a.status}} == 'completed') && ({{b.output}} == 'yes' || {{c.status}} == 'completed')"
```

## Built-in Evaluators

For use in `loop.until`:

| Name | Behavior |
|------|----------|
| `approved` | True if last output (trimmed, lowercased) is in: yes, y, approve, approved |
| `output_unchanged` | True if current output equals previous iteration output |

Custom evaluators can be defined in `.orc/evaluators/<name>.yml`.

## Providers

| Name | Description |
|------|-------------|
| `claude-code` | Claude Code CLI agent |
| `shell` | Shell command execution (default: `/bin/zsh`) |
| Custom | CLI agents configured in `.orc/config.yml` under `providers:` with `type: cli-agent` |

Custom provider config example in `.orc/config.yml`:
```yaml
providers:
  codex:
    type: cli-agent
    command: "codex -q '{{prompt}}'"
    interactive_command: "codex"
```

## Validation Rules

The parser enforces these rules. Violating any causes a validation error:

1. `name` must be non-empty
2. `nodes` must be non-empty
3. Every node must have a non-empty `id`
4. Node IDs must be unique
5. A node must have at least one of: `agent`, `command`, `workflow`, or `interactive: prompt`
6. Interactive prompt nodes must have a non-empty `message`
7. All `depends_on` references must point to existing node IDs
8. No circular dependencies (DAG validation)
9. All `{{variable}}` references in templates must resolve to known names (inputs, node IDs with `.output`/`.status`, output aliases, or builtins `repo_root`/`orc_root`/`workspace`/`last_output`)
10. Output aliases must not collide with other node IDs or input names
11. `when:` expressions must be syntactically valid (balanced parens, no dangling operators, no unterminated strings)
12. Workflow nodes must have a non-empty `inputs` mapping
13. Output map template variables must all resolve
