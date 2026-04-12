# Run Management

Orc persists every workflow run in a local SQLite database (`.orc/orc.db`). This page covers the commands for monitoring, inspecting, and cleaning up runs.

## Listing Runs

```sh
orc list
orc list --status completed
orc list --status failed
```

Displays a table of runs with columns: ID, WORKFLOW, STATUS, CREATED, UPDATED.

Filter by status: `pending`, `running`, `completed`, `failed`, `cancelled`, `awaiting_input`.

## Checking Run Status

```sh
orc status <runID>
```

Shows run details and a table of node executions (NODE, STATUS, ATTEMPT, ITERATION, STARTED, COMPLETED).

If any nodes are awaiting input, the output includes hints for the appropriate command (`orc attach` for session nodes, `orc respond` for prompt nodes).

## Viewing Logs

```sh
orc logs <runID>
orc logs <runID> --node build
orc logs <runID> --node build --attempt 2
orc logs <runID> --node review --iteration 3
```

| Flag | Description |
|------|-------------|
| `--node <id>` | Filter logs to a specific node |
| `--attempt <n>` | Filter by retry attempt number |
| `--iteration <n>` | Filter by loop iteration number |

## Resuming a Run

```sh
orc resume <runID>
```

Resumes a run that is in `failed` or `awaiting_input` status. Failed nodes are re-executed; awaiting-input nodes continue after a response has been provided.

## Cancelling a Run

```sh
orc cancel <runID>
```

Cancels a running workflow. All pending and running nodes are stopped.

## Cleaning Up Workspaces

Remove the workspace for a single run:

```sh
orc cleanup <runID>
```

Purge old runs and their workspaces in bulk:

```sh
orc purge --older-than 30d
orc purge --older-than 7d --status completed
orc purge --status all --older-than 90d
```

| Flag | Description |
|------|-------------|
| `--older-than <duration>` | Age threshold (e.g., `7d`, `30d`) |
| `--status <value>` | Filter: `pending`, `running`, `completed`, `failed`, `cancelled`, `awaiting_input`, `all` |

## Project Statistics

```sh
orc stats
```

Shows database path, database size, active workspace count, run counts by status, and the 10 most recent runs with duration information.

## Run Statuses

| Status | Description |
|--------|-------------|
| `pending` | Run created but not yet started |
| `running` | Nodes are actively executing |
| `awaiting_input` | Paused on an interactive node |
| `completed` | All nodes finished successfully |
| `failed` | One or more nodes failed |
| `cancelled` | Run was cancelled by the user |
