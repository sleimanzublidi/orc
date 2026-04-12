# Orc Web Monitor — Design Spec

A local web server for browser-based monitoring of Orc workflows. Provides a live dashboard showing running workflows, node execution progress, and historical run data. The server is a thin client over `OrcEngine`, serving an HTMX-powered frontend with SSE-driven live updates.

---

## 1. Module Structure

The web monitor is a new SPM library target (`Server`) that sits parallel to CLI in the dependency graph. Both are thin clients over the same Engine.

```
orc (executable)
 └─ CLI
     ├─ MonitorCommand         → Server
     ├─ StartCommand --monitor → Server
     └─ other commands         → Engine only
 └─ Server (new library target)
     ├─ depends on: Engine, Models, Hummingbird, swift-log
     ├─ MonitorServer (actor — lifecycle: start/stop/port binding)
     ├─ Routes (REST JSON endpoints + SSE stream)
     ├─ EventSource (protocol — abstracts polling vs future streaming)
     └─ Static assets (embedded HTML/HTMX/CSS resources via Bundle.module)
 └─ Engine (unchanged)
```

### Directory Layout

```
Orc/Core/Server/
├── Source/
│   ├── MonitorServer.swift        # Actor: server lifecycle (start/stop/url)
│   ├── Routes.swift               # Route registration
│   ├── RunRoutes.swift            # /api/runs, /api/runs/:id, /api/runs/:id/nodes
│   ├── LogRoutes.swift            # /api/runs/:id/nodes/:nodeID/logs
│   ├── StatsRoutes.swift          # /api/stats
│   ├── CatalogRoutes.swift        # /api/catalog
│   ├── EventRoutes.swift          # /api/events (SSE)
│   ├── HealthRoutes.swift         # /api/health
│   ├── PageRoutes.swift           # Server-rendered HTML pages (/, /runs/:id)
│   ├── EventSource.swift          # Protocol + polling implementation
│   ├── ServerError.swift          # Per-module typed errors
│   └── TemplateRenderer.swift     # HTML fragment rendering
├── Resources/
│   ├── index.html                 # Main page shell
│   ├── htmx.min.js               # Vendored HTMX (no CDN)
│   ├── styles.css                 # Dark theme
│   └── templates/                 # HTML fragments for HTMX swaps
│       ├── runs-list.html
│       ├── run-detail.html
│       ├── node-row.html
│       └── log-panel.html
└── Tests/
    ├── RouteTests.swift
    ├── EventSourceTests.swift
    └── TemplateRendererTests.swift
```

### Package.swift Changes

New dependency:

| Package | Version | Purpose |
|---------|---------|---------|
| [Hummingbird](https://github.com/hummingbird-project/hummingbird) | 2.x | HTTP server, routing, static files |

New target:

```swift
.target(
    name: "Server",
    dependencies: [
        "Engine",
        "Models",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
    ],
    path: "Orc/Core/Server",
    sources: ["Source"],
    resources: [.copy("Resources")]
)
```

CLI target gains a dependency on Server:

```swift
.target(
    name: "CLI",
    dependencies: ["Engine", "Models", "Server", ...],
    ...
)
```

---

## 2. REST API

All endpoints return JSON. Response bodies use existing `Codable` model types directly — no DTOs.

| Endpoint | Method | Engine Call | Response |
|----------|--------|------------|----------|
| `/api/health` | GET | — | `{"status":"ok"}` |
| `/api/runs` | GET | `listRuns(status:)` | `[Run]`, optional `?status=` filter |
| `/api/runs/:id` | GET | `getStatus(runID:)` | `Run` or 404 |
| `/api/runs/:id/nodes` | GET | `getNodeExecutions(runID:)` | `[NodeExecution]` |
| `/api/runs/:id/nodes/:nodeID/logs` | GET | `getLogs(runID:nodeID:attempt:iteration:)` | Log content (file contents read inline), optional `?attempt=&iteration=` |
| `/api/stats` | GET | `getStats()` | `[RunStats]` |
| `/api/catalog` | GET | `catalog()` | `Catalog` |
| `/api/events` | GET | — | SSE stream (see §3) |

### Log Content

`LogEntry` stores a `filePath` pointing to a log file on disk. The `/api/runs/:id/nodes/:nodeID/logs` endpoint reads the file contents and returns them inline as a JSON object with `stream`, `content`, and `timestamp` fields. Filesystem paths are never exposed to the browser.

### Server-Rendered Pages

In addition to the JSON API, the server renders full HTML pages for browser navigation:

| Path | Description |
|------|-------------|
| `/` | Dashboard — redirects to `/runs` |
| `/runs` | Runs list page (HTML) |
| `/runs/:id` | Run detail page (HTML) |

These pages are server-rendered HTML that loads HTMX for dynamic updates. HTMX issues requests to `/api/*` endpoints for partial page updates (e.g., swapping the runs list on status filter change).

---

## 3. Server-Sent Events (SSE)

### Endpoint

`GET /api/events` — opens a persistent SSE connection. Optional `?runID=` query parameter to scope events to a single run.

### Event Types

| Event | Payload | Trigger |
|-------|---------|---------|
| `run:created` | `Run` JSON | New run appears |
| `run:updated` | `Run` JSON | Run status changes |
| `node:updated` | `NodeExecution` JSON | Node status changes, new attempt/iteration |
| `heartbeat` | `{}` | Every 30 seconds (keep-alive) |

### Change Detection

The server maintains an in-memory snapshot of the last known state (map of run IDs → status, map of node execution IDs → status). On each poll tick (every 2 seconds):

1. Query `listRuns()` and `getNodeExecutions()` for active runs
2. Diff against snapshot
3. Emit events for changes
4. Update snapshot

### EventSource Protocol

```swift
protocol EventProviding: Sendable {
    func events() -> AsyncStream<MonitorEvent>
}
```

Initial implementation: `PollingEventSource` — polls the engine on a timer.

Future implementation: when `WorkflowEngine.startStreaming()` lands, a `StreamingEventSource` subscribes to the `AsyncThrowingStream<WorkflowEvent, Error>` and maps events directly. The SSE handler and browser code remain unchanged.

### Future-Aligned Event Types

The SSE event names are chosen to align with the planned `WorkflowEvent` enum for agent-level output streaming:

| Current (polling) | Future (streaming) |
|---|---|
| `run:created` | `run:created` |
| `run:updated` | `run:updated` |
| `node:updated` | `node:started` / `node:completed` / `node:failed` (more granular) |
| *(not available)* | `node:output` (streaming chunks) |
| `heartbeat` | `heartbeat` |

When streaming lands, `node:updated` can be split into the more granular events. The browser handles both — `node:updated` as a catch-all, and the specific events when available.

---

## 4. Frontend

### Technology

- **HTMX** — handles SSE subscriptions (`hx-ext="sse"`, `sse-connect`, `sse-swap`) and partial page updates (`hx-get`, `hx-swap`)
- **Server-rendered HTML** — the server returns HTML fragments, not JSON, for page-level endpoints. HTMX swaps fragments into the DOM.
- **Zero JS build step** — HTMX is vendored as a single `.min.js` file. Custom JS is minimal (log auto-scroll, relative time formatting).
- **Dark theme** — terminal-native aesthetic with status colors matching CLI output (green=completed, orange=running, red=failed, blue=awaiting input).

### Dashboard Views

#### Runs List (`/runs`)

- Table of all runs: status badge, workflow name, run ID, node progress (e.g., "3/5 nodes"), relative timestamp
- Status filter tabs: All / Running / Failed / Completed / Awaiting Input
- Filters use `hx-get="/api/runs?status=running"` with `hx-swap="innerHTML"` on the list container
- Live updates: SSE `run:created` and `run:updated` events trigger list refresh
- Click a run row to navigate to run detail

#### Run Detail (`/runs/:id`)

- Header: workflow name, run ID, status badge, start time, inputs
- Node list: each node as a collapsible row showing:
  - Status icon (✓ completed, ⟳ running, ✗ failed, ○ pending, ⏸ awaiting input)
  - Node name, agent type, attempt/iteration count
  - Duration (elapsed for running, total for completed)
  - Dependency info for pending nodes ("waiting on: X")
- Running nodes are highlighted (orange border) and auto-expanded
- Click any node row to expand/collapse log output
- Logs load on expand via `hx-get="/api/runs/:id/nodes/:nodeID/logs"` — not preloaded
- Log panel shows stdout/stderr with stream labels, monospace font, auto-scroll for running nodes
- SSE `node:updated` events for this run trigger node row replacement

#### Stats View (stretch)

- Aggregated statistics from `getStats()`: total runs, success rate, average duration
- Run history chart (if time permits — otherwise table)

#### Catalog View (stretch)

- List of available workflows and evaluators from `catalog()`

### Connection Status

Top-right indicator showing SSE connection state:
- Green dot + "Connected" — SSE stream active
- Red dot + "Disconnected" — SSE dropped, auto-reconnect in progress (SSE reconnects automatically)

### Static Assets

All assets bundled via SPM `resources` directive into `Bundle.module`:

```
Resources/
├── index.html          # Page shell: loads HTMX, CSS, establishes SSE
├── htmx.min.js         # Vendored HTMX 2.x
├── styles.css           # Dark theme, status colors, layout
└── templates/           # HTML fragments for server-side rendering
    ├── runs-list.html   # Run rows for the list view
    ├── run-detail.html  # Full run detail page
    ├── node-row.html    # Single node execution row
    └── log-panel.html   # Expandable log output panel
```

---

## 5. CLI Integration

### `orc monitor` Command

New subcommand under the main `orc` command.

```
orc monitor [--port <port>] [--host <host>] [--no-open]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--port` | 9621 | Port to bind |
| `--host` | 127.0.0.1 | Host to bind (use 0.0.0.0 for network access) |
| `--no-open` | false | Skip auto-opening browser |

Behavior:
1. Instantiate `WorkflowEngine` with the current `.orc` directory
2. Create `MonitorServer(engine:host:port:)`
3. Call `server.start()`
4. Unless `--no-open`, open browser via `open <url>` (macOS) / `xdg-open <url>` (Linux)
5. Block on signal (SIGINT/SIGTERM)
6. On signal: call `server.stop()`, exit cleanly

### `orc start --monitor` Flag

New optional flag on the existing `start` command.

Behavior:
1. Check if port 9621 is already in use
   - If yes: hit `/api/health` — if it responds, reuse the existing server
   - If no: start a new `MonitorServer` in a child task
2. Start the workflow via `engine.start()`
3. Open browser to `http://<host>:<port>/runs/<runID>`
4. After workflow completes, keep server alive for 30 seconds for review, then shut down
5. If using an existing server, skip shutdown

### Port Conflict Handling

When the requested port is occupied:
- `orc monitor`: attempt `/api/health` check. If it's an existing orc monitor, print URL and exit. If not, fail with error suggesting `--port`.
- `orc start --monitor`: attempt `/api/health` check. If it's an existing orc monitor, reuse it. If not, fail with error.

---

## 6. Server Lifecycle

### MonitorServer Actor

```swift
public actor MonitorServer {
    public init(engine: WorkflowEngine, host: String, port: Int)
    public func start() async throws
    public func stop() async
    public nonisolated var url: URL { get }
}
```

- `start()` — configures Hummingbird app, registers routes, binds to host:port, starts serving. Throws `ServerError` on bind failure.
- `stop()` — graceful shutdown. Closes SSE connections, stops the Hummingbird server.
- The actor holds the Hummingbird `Application` instance and the `EventSource`.

### Graceful Shutdown

- SIGINT/SIGTERM caught in the CLI command layer (not in the server)
- CLI calls `server.stop()` which triggers Hummingbird's graceful shutdown
- In-flight SSE connections receive a close event
- Server waits up to 5 seconds for connections to drain

---

## 7. Testing Strategy

### Route Tests (unit)

- Inject a mock `OrcEngineProviding` into route handlers
- Test each route with known model data
- Verify JSON response bodies match expected shapes
- Verify status codes (200, 404 for missing run, etc.)
- Verify query parameter filtering (`?status=running`, `?attempt=1`)
- Use Hummingbird's `Application.test` for in-process request/response — no real TCP

### SSE / EventSource Tests (unit)

- Mock engine that returns different states on successive queries
- Verify `PollingEventSource` emits correct events on state changes
- Verify no events emitted when state is unchanged
- Verify `runID` filtering
- Verify heartbeat timing

### Template Rendering Tests (unit)

- Verify HTML fragments render correctly for various model states
- Running node, completed node, failed node, skipped node
- Empty runs list, run with no nodes yet
- Log panel with stdout + stderr content

### Integration Tests

- Start a real `MonitorServer` on port 0 (random available port)
- Use `URLSession` to hit JSON API endpoints end-to-end
- Verify static asset serving (HTMX JS loads, CSS loads)
- Verify SSE connection can be established

### Out of Scope

- Browser-level testing (HTMX interactions, visual rendering) — manual testing
- Engine/store/model tests — already covered in existing modules

---

## 8. Error Handling

### ServerError (typed, per-module)

```swift
public enum ServerError: Error, Sendable {
    case bindFailed(host: String, port: Int, underlying: Error)
    case portInUse(port: Int)
    case logFileNotFound(path: String)
    case engineError(String)
}
```

### API Error Responses

All API errors return JSON:

```json
{
  "error": "Run not found",
  "code": "not_found"
}
```

| Scenario | Status | Code |
|----------|--------|------|
| Run not found | 404 | `not_found` |
| Invalid status filter | 400 | `invalid_parameter` |
| Engine error | 500 | `engine_error` |
| Log file missing from disk | 404 | `log_not_found` |

---

## 9. Configuration

No new configuration keys in `OrcConfig`. Server settings (port, host) are CLI flags only — they're transient runtime settings, not persisted configuration.

Default port: **9621** (arbitrary, avoids common conflicts).

---

## 10. Security

- **Localhost only by default** — no network exposure unless explicitly opted in via `--host 0.0.0.0`
- **No authentication** — the server is a local development tool, not a production service. Network exposure is the user's responsibility.
- **No filesystem path exposure** — log file paths are never sent to the browser; contents are read and returned inline.
- **No write operations** — the web server is read-only. No endpoints to start, cancel, or modify runs. That's the CLI's job.
