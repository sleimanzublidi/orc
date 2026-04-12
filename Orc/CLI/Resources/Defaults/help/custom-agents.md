# Custom CLI Agents

Define your own providers to integrate any CLI tool into Orc workflows.

## Defining a Custom Agent

Add a provider entry to `.orc/config.yml` with `type: cli-agent`:

```yaml
providers:
  my-agent:
    type: cli-agent
    command: "my-tool --prompt {{prompt}}"
    interactive_command: "my-tool --interactive"
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Must be `"cli-agent"` |
| `command` | string | yes | Command template; `{{prompt}}` is replaced at runtime |
| `interactive_command` | string | no | Command to run in tmux for interactive session mode |

## Using a Custom Agent

Reference the agent by its config key name:

```yaml
nodes:
  - id: generate
    agent: my-agent
    prompt: "Generate a REST API for a todo app"
```

## How It Works

1. At startup, the engine reads provider entries from `.orc/config.yml`.
2. Entries with `type: cli-agent` and a `command` are registered as custom providers.
3. When a node runs, `{{prompt}}` in the command template is replaced with the node's resolved prompt (single-quote escaped to prevent shell injection).
4. The command is executed via the system shell.
5. Stdout is captured as the node's output.

## Examples

### Codex

```yaml
providers:
  codex:
    type: cli-agent
    command: "codex --prompt {{prompt}} --approval-mode full-auto"
```

### Gemini CLI

```yaml
providers:
  gemini:
    type: cli-agent
    command: "gemini -p {{prompt}}"
```

### Custom Script

```yaml
providers:
  analyzer:
    type: cli-agent
    command: "python3 scripts/analyze.py --query {{prompt}}"
```

## Interactive Mode

If `interactive_command` is configured, the agent supports `interactive: session` on nodes. The interactive command runs inside a tmux session that you can attach to with `orc attach`.

```yaml
providers:
  my-agent:
    type: cli-agent
    command: "my-tool --prompt {{prompt}}"
    interactive_command: "my-tool --chat"
```

```yaml
nodes:
  - id: chat
    agent: my-agent
    interactive: session
    prompt: "Help me debug this issue"
```

If `interactive_command` is not configured and a node requests interactive mode, the node will fail with an error.
