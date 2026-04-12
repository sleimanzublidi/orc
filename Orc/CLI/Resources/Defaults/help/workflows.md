# Writing Workflows

Orc workflows are YAML files that define a directed acyclic graph (DAG) of nodes. Nodes run in parallel when their dependencies allow it; the engine resolves execution order automatically via topological sort.

## Quick Start

```yaml
name: greet
description: Say hello via the shell

nodes:
  - id: hello
    agent: shell
    command: echo "Hello, world!"
```

Run it:

```sh
orc start greet
```

## Schema Reference

### Top-Level Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | yes | -- | Workflow name |
| `description` | string | no | -- | Human-readable description |
| `input` | list | no | `[]` | Declared input parameters |
| `nodes` | list | yes | -- | One or more node definitions |
| `output` | map | no | -- | Output mapping (values are template strings) |
| `cleanup` | string | no | `"30d"` | Workspace cleanup policy |

### Input Parameters

```yaml
input:
  - name: repo_path
    type: file
    required: true
  - name: branch
    type: string
    required: false
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | -- | Parameter name, referenced as `{{name}}` in templates |
| `type` | string | `"string"` | `string` or `file` |
| `required` | bool | `true` | Whether the input must be provided |

Pass inputs at the command line:

```sh
orc start deploy --input env=staging --input region=us-east-1
orc start review --file ./src/main.swift
```

A single trailing argument is assigned to the first `type: string` input:

```sh
orc start ask-claude "What is the meaning of life?"
```

### Node Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | string | -- | Unique identifier within the workflow |
| `agent` | string | -- | Provider: `claude-code`, `shell`, or a custom agent name |
| `prompt` | string | -- | Template string sent to the agent |
| `command` | string | -- | Shell command (for `shell` agent; supports templates) |
| `depends_on` | string or list | `[]` | Node IDs that must complete first |
| `output` | string | -- | Alias name, making this node's output available as `{{alias}}` |
| `when` | string | -- | Guard expression; node is skipped when false |
| `loop` | object | -- | Loop configuration (see [Loops](loops.md)) |
| `interactive` | string | -- | `"session"` or `"prompt"` (see [Interactive Nodes](interactive-nodes.md)) |
| `message` | string | `""` | Message shown for prompt-mode interactive nodes |
| `retry` | object | -- | Retry configuration |
| `timeout_seconds` | int | -- | Execution timeout |
| `on_failure` | string | `"stop"` | `stop`, `skip`, or `continue` |
| `workflow` | string | -- | Path to child workflow (see [Nested Workflows](nested-workflows.md)) |
| `inputs` | map | -- | Input mapping for nested workflows |
| `workspace` | string | `"shared"` | Nested workflow workspace mode: `shared` or `isolated` |
| `parameters` | map | `{}` | Provider-specific key-value pairs (see [Providers](providers.md)) |

### Dependencies and Parallelization

Nodes without dependencies (or whose dependencies have completed) run in parallel, up to `max_parallel_nodes` (default: CPU core count).

```yaml
nodes:
  - id: lint
    agent: shell
    command: swiftlint

  - id: test
    agent: shell
    command: swift test

  # Runs after both lint and test complete
  - id: deploy
    agent: shell
    command: ./deploy.sh
    depends_on: [lint, test]
```

### Conditional Execution

The `when` field accepts expressions with `==`, `!=`, `&&`, `||`, `!`, and parentheses:

```yaml
- id: deploy
  agent: shell
  command: ./deploy.sh
  depends_on: [approve]
  when: "{{approve.output}} == 'yes'"
```

A node skipped by `when` does not cascade unconditionally. Downstream nodes run if at least one of their dependencies completed.

### Retry

```yaml
- id: flaky-api
  agent: shell
  command: curl https://api.example.com/health
  retry:
    max_attempts: 3
    delay_seconds: 5
```

### Failure Handling

| `on_failure` | Behavior |
|--------------|----------|
| `stop` | Cancel all remaining nodes (default) |
| `skip` | Skip downstream dependents |
| `continue` | Let downstream nodes run despite the failure |

### Output Mapping

Map node outputs to named workflow outputs:

```yaml
output:
  summary: "{{summarize.output}}"
  status: "{{deploy.status}}"
```

### Cleanup Policy

| Value | Behavior |
|-------|----------|
| `on_success` | Remove workspace after successful completion |
| `always` | Always remove workspace |
| `never` | Never auto-remove |
| `<N>d` | Remove after N days (e.g., `30d`) |

## Validation

Validate a workflow without running it:

```sh
orc validate deploy.yaml
```

Reports node count, input count, structural errors, and warnings (e.g., unresolved template variables).

## Template Variables

See [Templates](templates.md) for variable syntax, resolution order, default filters, and escape sequences.
