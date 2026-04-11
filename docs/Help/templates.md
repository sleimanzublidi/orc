# Template Variables

Orc uses `{{variable}}` syntax for dynamic values in prompts, commands, `when` expressions, nested workflow inputs, and output mappings.

## Syntax

```yaml
prompt: "Review the code in {{workspace}}/src"
command: "echo {{greeting | default: hello}}"
when: "{{review.status}} == 'completed'"
```

## Resolution Order

When resolving `{{name}}`, the engine checks in this order:

1. **Dot-qualified output** -- `{{node_id.output}}` resolves to the output of the named node.
2. **Dot-qualified status** -- `{{node_id.status}}` resolves to the node's status string (`completed`, `failed`, `skipped`, etc.).
3. **Built-in `workspace`** -- resolves to the run's workspace directory path.
4. **Built-in `last_output`** -- the previous loop iteration's output (only meaningful inside loops).
5. **Input** -- matches a declared workflow input name.
6. **Output alias** -- matches a node's `output` alias name.

If none match, resolution fails with an error (unless a default filter is present).

## Default Filter

Provide a fallback value for unresolved variables:

```yaml
prompt: "Hello, {{name | default: World}}!"
```

If `name` is not set, the result is `Hello, World!`. If `name` is set, the default is ignored.

The filter syntax is `| default: <value>`, where everything after `default:` (trimmed) is the fallback.

## Escaping

Use `\{{` to produce a literal `{{` in the output. This is useful when prompts contain Jinja, Mustache, or Go template syntax that should not be resolved:

```yaml
prompt: |
  Generate a Go template like: \{{.Name}}
```

## Available Variables

| Variable | Source |
|----------|--------|
| `{{input_name}}` | Declared workflow inputs |
| `{{node_id.output}}` | Output of a completed node |
| `{{node_id.status}}` | Status of a node |
| `{{alias_name}}` | A node's `output:` alias |
| `{{workspace}}` | Run workspace directory |
| `{{last_output}}` | Previous loop iteration output |

## Where Templates Are Resolved

- Node `prompt`
- Node `command`
- Node `when` expressions
- Nested workflow `inputs` values
- Workflow-level `output` values

## Examples

```yaml
nodes:
  - id: analyze
    agent: claude-code
    prompt: "Analyze {{file_path}}"
    output: analysis

  - id: report
    agent: shell
    command: "echo '{{analysis}}' > {{workspace}}/report.txt"
    depends_on: analyze
```
