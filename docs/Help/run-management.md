# Run Management

Orc persists every workflow run in a local SQLite database (`.orc/orc.db`). This page covers the commands for monitoring, inspecting, and cleaning up runs.

## Listing Runs

```sh
orc list
orc list --status completed
orc list --status failed
orc list --all
```

Displays a table of runs with columns: ID, WORKFLOW, STATUS, CREATED, UPDATED.

By default, only top-level runs are shown. Child runs spawned by nested workflows are hidden. Use `--all` to include them.

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

## Checking In-Progress Runs

```sh
orc status
```

Without a run ID, shows all in-progress runs (pending, running, awaiting_input) in a table.

## Cleaning Up Workspaces

Remove workspaces without deleting database records. Supports a run ID, status filter, date filter, or `all`:

```sh
orc cleanup <runID>
orc cleanup all
orc cleanup completed
orc cleanup '<2026-04-15'
orc cleanup --status failed --older-than 30d
orc cleanup completed --older-than 7d
orc cleanup --dry-run all
```

| Positional | Description |
|------------|-------------|
| `<runID>` | Single run workspace |
| `all` | All workspaces |
| `<status>` | Filter by status |
| `<YYYY-MM-DD` | Runs updated before that date |

| Flag | Description |
|------|-------------|
| `--older-than <value>` | Duration (`7d`, `30d`) or ISO date (`2026-04-15`) |
| `--status <value>` | `pending`, `running`, `completed`, `failed`, `cancelled`, `awaiting_input`, `all` |
| `--dry-run` | Show what would be removed without removing |

## Purging Runs

Delete run records from the database **and** their workspaces. Same filter syntax as `cleanup`:

```sh
orc purge
orc purge all
orc purge completed
orc purge '<2026-04-15'
orc purge --older-than 30d
orc purge --older-than 7d --status completed
orc purge --dry-run completed
```

With no arguments, purges all runs. Use `--dry-run` to preview what would be deleted.

| Positional | Description |
|------------|-------------|
| `all` | All runs |
| `<status>` | Filter by status |
| `<YYYY-MM-DD` | Runs updated before that date |

| Flag | Description |
|------|-------------|
| `--older-than <value>` | Duration (`7d`, `30d`) or ISO date (`2026-04-15`) |
| `--status <value>` | `pending`, `running`, `completed`, `failed`, `cancelled`, `awaiting_input`, `all` |
| `--dry-run` | Show what would be purged without purging |

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
