# Built-in Providers

Orc ships with two built-in providers: `claude-code` and `shell`. Each node's `agent` field selects which provider executes it.

## claude-code

Sends a prompt to [Claude Code](https://claude.ai/code) and captures the result.

```yaml
- id: analyze
  agent: claude-code
  prompt: "Analyze the architecture of this project."
```

**How it works:** Runs `claude -p <prompt> --output-format json --permission-mode <mode>`, parses the JSON response, and extracts the result text.

### Permission Mode

The `permission_mode` node field controls which tools the agent can use without prompting. Defaults to `acceptEdits` if not specified.

```yaml
- id: implement
  agent: claude-code
  prompt: "Implement the feature"
  permission_mode: full          # auto-approve all tools
```

| Value | Behavior |
|-------|----------|
| `default` | Claude Code default permission handling |
| `acceptEdits` | Auto-approve file edits and common filesystem commands (default) |
| `full` | Auto-approve all tools including shell commands |
| `plan` | Plan-only mode — no edits or execution |
| `bypassPermissions` | Bypass all permission checks |

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

**How it works:** Passes the command to the configured shell via its `-c` flag. Default shell is `/bin/zsh`.

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

## See Also

- [Custom Agents](custom-agents.md) for defining your own providers.
- [Interactive Nodes](interactive-nodes.md) for session and prompt modes.
