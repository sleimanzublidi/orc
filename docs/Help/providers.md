# Providers

Orc ships with two built-in providers: `claude-code` and `shell`. Each node's `agent` field selects which provider executes it.

Custom CLI agents can add providers such as `copilot`, `codex`, or project-specific tools. To keep workflows portable across agents, declare an input and template the `agent` field:

```yaml
input:
  - name: agent
    type: string
    default: "claude-code"

nodes:
  - id: implement
    agent: "{{agent}}"
    prompt_file: "{{orc_root}}/prompts/implement-task.md"
```

Then run with any configured provider:

```sh
orc start implement-task --input agent="copilot"
```

## claude-code

Sends a prompt to [Claude Code](https://claude.ai/code) and captures the result.

```yaml
- id: analyze
  agent: claude-code
  prompt: "Analyze the architecture of this project."
```

**How it works:** Runs `claude -p <prompt> --output-format json --permission-mode <mode>`, parses the JSON response, and extracts the result text. Additional flags (`--bare`, `--model`) are added based on the node's `parameters:` block.

### Parameters

The `parameters:` block on a node passes provider-specific configuration. The `claude-code` provider reads these keys:

```yaml
- id: implement
  agent: claude-code
  prompt: "Implement the feature"
  parameters:
    permission_mode: dontAsk      # auto-approve all tools
    bare: "true"                  # minimal mode (needs ANTHROPIC_API_KEY in .env)
    model: opus                   # override model
```

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `permission_mode` | `default`, `acceptEdits`, `dontAsk`, `plan`, `auto`, `bypassPermissions` | `acceptEdits` | Controls which tools the agent can use without prompting |
| `bare` | `true` / `false` | `false` | Minimal mode: skips hooks, LSP, CLAUDE.md auto-discovery. Requires `ANTHROPIC_API_KEY` in `.orc/.env` |
| `model` | model alias or full name | (Claude default) | Override the model (e.g., `opus`, `sonnet`) |

Parameter values support `{{template}}` syntax, so a parent workflow can pass provider config to a child:

```yaml
parameters:
  permission_mode: "{{mode}}"
```

### Environment (.env)

Orc loads `.orc/.env` before each workflow run. Variables are passed to all provider child processes. Use this to supply `ANTHROPIC_API_KEY` when using `bare: "true"`.

Process environment variables take precedence over `.env` values.

### Configuration

In `.orc/config.yml`:

```yaml
providers:
  claude-code:
    path: /usr/local/bin/claude    # Path to the claude CLI binary
```

### Interactive Mode

When combined with `interactive: session`, creates a tmux session running the Claude CLI in interactive mode (no `-p` flag). Attach with `orc attach`.

## shell

Runs a shell command and captures stdout as the node output.

```yaml
- id: build
  agent: shell
  command: "swift build -c release 2>&1"
```

Use the `command` field instead of `prompt` for shell nodes. Template variables are resolved before execution.

**How it works:** Passes the command to the configured shell via its `-c` flag. Default shell is `/bin/zsh` on macOS and `/bin/sh` on Linux.

Shell nodes do not use any `parameters:` keys. Any keys in the `parameters:` block are ignored.

Generic `cli-agent` providers also ignore unknown `parameters:` keys. Put custom CLI flags in the provider's configured `command` instead.

### Configuration

In `.orc/config.yml`:

```yaml
providers:
  shell:
    default_shell: /bin/zsh
```

Or set globally:

```yaml
default_shell: /bin/bash
```

### Interactive Mode

When combined with `interactive: session`, creates a tmux session running the command. Useful for long-running processes that need manual interaction.

## Provider Behavior

- Both providers capture stdout and stderr to temporary files.
- Only stdout becomes the node's output.
- A non-zero exit code causes the node to fail (respecting `retry` and `on_failure` settings).
- Stderr is logged but not included in the output.
- Environment variables from `.orc/.env` and the process environment are passed to all child processes.

## See Also

- [Custom Agents](custom-agents.md) for defining your own providers.
- [Interactive Nodes](interactive-nodes.md) for session and prompt modes.
