# Interactive Nodes

Interactive nodes pause workflow execution to allow human interaction, either through a terminal session or a prompt-response exchange.

## Session Mode

Creates a tmux session that you can attach to. The workflow resumes when the session ends.

```yaml
- id: review
  agent: "{{agent | default: claude-code}}"
  interactive: session
  prompt: "Review the changes in this repository"
```

### Workflow

1. The provider starts a tmux session named `orc-<runID>-<nodeID>`.
2. The node enters `awaiting_input` status and the run pauses.
3. Attach to the session:

   ```sh
   orc attach <runID> <nodeID>
   ```

4. Work in the session. When you exit (or the process finishes), the engine captures the terminal output and resumes the workflow.

Session mode requires an `agent` field. The provider's interactive command runs inside the tmux session.

## Prompt Mode

Pauses the workflow and waits for a text or file response. No agent or tmux session is involved.

```yaml
- id: approve
  interactive: prompt
  message: "Deploy to production? (yes/no)"
  output: approval
```

### Workflow

1. The node enters `awaiting_input` status and displays the `message`.
2. Check the status to see the prompt:

   ```sh
   orc status <runID>
   ```

3. Respond with text:

   ```sh
   orc respond <runID> <nodeID> "yes"
   ```

   Or respond with a file:

   ```sh
   orc respond <runID> <nodeID> --file ./report.pdf
   ```

   File responses are copied into the run's workspace and the path `artifacts/<filename>` becomes the node output.

4. Resume the workflow:

   ```sh
   orc resume <runID>
   ```

## Combining with Loops

Session mode works with loops. Each iteration creates a new tmux session (`orc-<runID>-<nodeID>-iter<N>`):

```yaml
- id: iterate
  agent: "{{agent | default: claude-code}}"
  interactive: session
  prompt: "Fix the failing tests"
  loop:
    until: tests_pass
    max_iterations: 3
```

## Combining with Dependencies

Interactive nodes participate in the DAG like any other node. Downstream nodes wait until the interactive node completes:

```yaml
nodes:
  - id: approve
    interactive: prompt
    message: "Approve deployment? (yes/no)"
    output: approval

  - id: deploy
    agent: shell
    command: ./deploy.sh
    depends_on: approve
    when: "{{approval}} == 'yes'"
```
