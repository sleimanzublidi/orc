---
name: orc-workflow
description: Use when creating, generating, scaffolding, or modifying Orc workflow YAML files, or when the user asks to build an automation workflow for Orc
---

# Orc Workflow

Create and modify Orc workflow YAML files.

## File Access Restriction

When creating or modifying workflows, **ONLY** read files from:
1. This skill's directory (e.g., `schema.md`)
2. The `.orc/` folder at the root of the repository

Do **NOT** read any other files in the codebase. All information needed to generate valid workflows is contained in the schema reference and existing workflow files in `.orc/`.

## Schema Reference

**ALWAYS** read `schema.md` from this skill's directory before generating or modifying any workflow. It contains the complete YAML schema — all fields, types, defaults, validation rules, template syntax, expression syntax, and providers.

## Creation Workflow

When the user asks to create a new workflow:

1. **Parse the request** to identify: nodes (steps), agents (`claude-code`, `shell`, or custom), dependencies between nodes, inputs/outputs, and any advanced features (loops, conditionals, retries, interactive prompts).

2. **If the request is clear**, generate the full YAML directly. Do not ask unnecessary questions. Most workflows are straightforward — a few nodes with obvious ordering.

3. **If the request is ambiguous**, ask targeted clarifying questions — one at a time, multiple choice preferred. Common ambiguities:
   - Which agent to use for a step (shell vs claude-code)
   - Dependency ordering when steps could run in parallel or sequentially
   - Whether an input should be required or optional
   - Whether a loop/retry is needed

4. **Write the file** to `.orc/workflows/<name>.yaml`. Use kebab-case for the filename (e.g., `review-pr.yaml`).

5. **Add a comment header** at the top of the file matching this template:
   ```yaml
   # <Short description of what the workflow does>.
   #
   # Usage:
   #   orc start <name>
   #   orc start <name> --input <key>="<value>"
   #   orc start <name> "<positional input value>"
   ```
   Include all meaningful input variations. Match the style of the examples below.

6. **Validate** by running `orc validate .orc/workflows/<name>.yaml`. If validation fails, fix the issue and re-validate until it passes.

## Modification Workflow

When the user asks to modify an existing workflow:

1. **Read the existing workflow file** in full.
2. **Apply the requested change** — add/remove/modify nodes, change dependencies, add/remove inputs, update prompts, adjust loop/retry/when config, etc.
3. **Preserve the comment header** — update usage examples if inputs changed.
4. **Write the updated file**.
5. **Validate** by running `orc validate <path>`. Fix and re-validate on failure.

## Generation Guidelines

- Use `output` aliases on nodes to create clean variable names (e.g., `output: summary` instead of referencing `{{summarize.output}}`).
- Use `| default:` for optional inputs so workflows work without arguments.
- Prefer `claude-code` for tasks requiring reasoning, analysis, or code generation. Use `shell` for deterministic commands (echo, file operations, scripts).
- Set `depends_on` only when a node actually needs another node's output or must run after it. Nodes without dependencies run in parallel automatically.
- Use `when:` guards for conditional branching — not for sequencing (that's what `depends_on` is for).
- Use `on_failure: continue` when downstream nodes should still run despite a failure. Use `on_failure: skip` when the node is optional.
- Keep prompts focused. For `claude-code` nodes, be explicit about what files to read/not read.

## Examples

### Simple Single-Node

```yaml
# Greet using shell.
#
# Usage:
#   orc start greet
#   orc start greet --input name="Alice"
name: greet
description: Prints a personalized greeting.

input:
  - name: name
    type: string
    required: false

nodes:
  - id: greet
    agent: shell
    prompt: "echo 'Hello, {{name | default: World}}!'"
    output: message

output:
  greeting: "{{message}}"
```

### Multi-Node with Dependencies

```yaml
# Analyze a file: summarize, then suggest improvements.
#
# Usage:
#   orc start analyze --input file="src/main.swift"
name: analyze
description: Summarizes a file and suggests improvements.

input:
  - name: file
    type: file
    required: true

nodes:
  - id: summarize
    agent: claude-code
    prompt: "Read {{file}} and provide a brief summary."
    output: summary

  - id: improve
    agent: claude-code
    prompt: "Given this summary of {{file}}:\n\n{{summary}}\n\nSuggest concrete improvements."
    depends_on: summarize
    output: suggestions

output:
  summary: "{{summary}}"
  suggestions: "{{suggestions}}"
```

### Advanced — Loop with Conditional

```yaml
# Iterative code review loop.
#
# Usage:
#   orc start review-loop --input file="src/module.swift"
name: review-loop
description: Reviews a file iteratively until all issues are resolved.

input:
  - name: file
    type: file
    required: true

nodes:
  - id: review
    agent: claude-code
    prompt: "Review {{file}} for bugs and style issues. List each issue on its own line. If no issues remain, say APPROVED."
    output: review_result
    loop:
      until: approved
      max_iterations: 5

  - id: fix
    agent: claude-code
    prompt: "Fix the issues found in {{file}}:\n\n{{review_result}}"
    depends_on: review
    when: "{{review.status}} == 'completed'"

output:
  review: "{{review_result}}"
```
