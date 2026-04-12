# Web Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local web server to Orc that provides browser-based monitoring of workflow runs via `orc monitor` and `orc start --monitor`.

**Architecture:** New `Server` SPM library target parallel to CLI, both thin clients over `WorkflowEngine`. Hummingbird 2 serves a REST JSON API, SSE event stream, and HTMX-powered dark-themed dashboard. All HTML/CSS/JS bundled as SPM resources.

**Tech Stack:** Swift 6.1, Hummingbird 2, HTMX 2.x (vendored), SSE via ResponseBody streaming, Swift Testing

---

### File Map

**New files (Server module):**
- `Orc/Core/Server/Source/ServerError.swift` — typed error enum
- `Orc/Core/Server/Source/MonitorEvent.swift` — SSE event model
- `Orc/Core/Server/Source/TemplateRenderer.swift` — HTML fragment rendering
- `Orc/Core/Server/Source/EventSource.swift` — EventProviding protocol + PollingEventSource
- `Orc/Core/Server/Source/RunRoutes.swift` — /api/runs, /api/runs/:id, /api/runs/:id/nodes
- `Orc/Core/Server/Source/LogRoutes.swift` — /api/runs/:id/nodes/:nodeID/logs
- `Orc/Core/Server/Source/StatsRoutes.swift` — /api/stats
- `Orc/Core/Server/Source/CatalogRoutes.swift` — /api/catalog
- `Orc/Core/Server/Source/EventRoutes.swift` — /api/events (SSE)
- `Orc/Core/Server/Source/HealthRoutes.swift` — /api/health
- `Orc/Core/Server/Source/PageRoutes.swift` — HTML page routes (/, /runs, /runs/:id)
- `Orc/Core/Server/Source/MonitorServer.swift` — public actor, server lifecycle
- `Orc/Core/Server/Resources/styles.css` — dark theme CSS
- `Orc/Core/Server/Resources/htmx.min.js` — vendored HTMX 2.x
- `Orc/Core/Server/Resources/index.html` — page shell
- `Orc/Core/Server/Tests/TemplateRendererTests.swift`
- `Orc/Core/Server/Tests/EventSourceTests.swift`
- `Orc/Core/Server/Tests/RouteTests.swift`

**New files (CLI):**
- `Orc/CLI/Source/Commands/MonitorCommand.swift` — `orc monitor` subcommand

**Modified files:**
- `Orc/Package.swift` — add Hummingbird dependency, Server target, update CLI deps
- `Orc/CLI/Source/Commands/OrcCommand.swift` — register MonitorCommand
- `Orc/CLI/Source/Commands/StartCommand.swift` — add `--monitor` flag

---

### Task 1: Package.swift — Add Hummingbird Dependency and Server Target

**Files:**
- Modify: `Orc/Package.swift`

- [ ] **Step 1: Add Hummingbird package dependency**

In `Orc/Package.swift`, add to the `dependencies` array:

```swift
.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
```

- [ ] **Step 2: Add Server library target**

Add to the `targets` array, after the `Engine` target and before the `CLI` target:

```swift
.target(
    name: "Server",
    dependencies: [
        "Engine",
        "Models",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
    ],
    path: "Core/Server",
    sources: ["Source"],
    resources: [.copy("Resources")]
),
```

- [ ] **Step 3: Add Server dependency to CLI target**

In the `CLI` target's dependencies array, add `"Server"`:

```swift
.target(
    name: "CLI",
    dependencies: [
        "Engine",
        "Models",
        "Server",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
    ],
    ...
),
```

- [ ] **Step 4: Add Server test target**

Add to the `targets` array:

```swift
.testTarget(
    name: "ServerTests",
    dependencies: [
        "Server",
        "Models",
        "Engine",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
    ],
    path: "Core/Server/Tests"
),
```

- [ ] **Step 5: Create directory structure**

```bash
mkdir -p Orc/Core/Server/Source
mkdir -p Orc/Core/Server/Tests
mkdir -p Orc/Core/Server/Resources/templates
```

- [ ] **Step 6: Create placeholder file so SPM resolves**

Create `Orc/Core/Server/Source/ServerError.swift`:

```swift
public enum ServerError: Error, Sendable {
    case bindFailed(host: String, port: Int, underlying: any Error)
    case portInUse(port: Int)
    case logFileNotFound(path: String)
    case engineError(String)
}
```

Create empty `Orc/Core/Server/Resources/index.html`:

```html
<!DOCTYPE html>
<html><body>placeholder</body></html>
```

- [ ] **Step 7: Verify package resolves**

Run: `cd Orc && swift package resolve`
Expected: successful dependency resolution including hummingbird

- [ ] **Step 8: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds (Server target compiles with just the error enum)

- [ ] **Step 9: Commit**

```bash
git add Orc/Package.swift Orc/Core/Server/
git commit -m "[Claude] Add Server SPM target with Hummingbird dependency"
```

---

### Task 2: MonitorEvent Model and TemplateRenderer

**Files:**
- Create: `Orc/Core/Server/Source/MonitorEvent.swift`
- Create: `Orc/Core/Server/Source/TemplateRenderer.swift`
- Create: `Orc/Core/Server/Tests/TemplateRendererTests.swift`

- [ ] **Step 1: Write MonitorEvent model**

Create `Orc/Core/Server/Source/MonitorEvent.swift`:

```swift
import Models
import Foundation

public enum MonitorEvent: Sendable {
    case runCreated(Run)
    case runUpdated(Run)
    case nodeUpdated(NodeExecution)
    case heartbeat

    var eventName: String {
        switch self {
        case .runCreated: "run:created"
        case .runUpdated: "run:updated"
        case .nodeUpdated: "node:updated"
        case .heartbeat: "heartbeat"
        }
    }

    func jsonPayload(encoder: JSONEncoder) throws -> String {
        switch self {
        case .runCreated(let run):
            return String(data: try encoder.encode(run), encoding: .utf8) ?? "{}"
        case .runUpdated(let run):
            return String(data: try encoder.encode(run), encoding: .utf8) ?? "{}"
        case .nodeUpdated(let node):
            return String(data: try encoder.encode(node), encoding: .utf8) ?? "{}"
        case .heartbeat:
            return "{}"
        }
    }

    func sseFormatted(encoder: JSONEncoder) throws -> String {
        let data = try jsonPayload(encoder: encoder)
        return "event: \(eventName)\ndata: \(data)\n\n"
    }
}
```

- [ ] **Step 2: Write TemplateRenderer**

Create `Orc/Core/Server/Source/TemplateRenderer.swift`:

```swift
import Models
import Foundation

enum TemplateRenderer {

    // MARK: - Run List

    static func renderRunsList(_ runs: [Run]) -> String {
        if runs.isEmpty {
            return """
            <div class="empty-state">
                <p>No workflow runs found.</p>
            </div>
            """
        }
        return runs.map { renderRunRow($0) }.joined(separator: "\n")
    }

    static func renderRunRow(_ run: Run) -> String {
        let statusClass = statusCSSClass(run.status)
        let statusLabel = run.status.rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
        let timeAgo = relativeTime(run.updatedAt)
        return """
        <a href="/runs/\(run.id)" class="run-row" hx-get="/runs/\(run.id)" hx-target="#content" hx-push-url="true">
            <div class="run-row-left">
                <span class="status-badge \(statusClass)">\(statusLabel)</span>
                <span class="run-name">\(escapeHTML(run.workflowName))</span>
                <code class="run-id">\(run.id)</code>
            </div>
            <div class="run-row-right">
                <span class="run-time">\(timeAgo)</span>
            </div>
        </a>
        """
    }

    // MARK: - Run Detail

    static func renderRunDetail(_ run: Run, nodes: [NodeExecution]) -> String {
        let statusClass = statusCSSClass(run.status)
        let statusLabel = run.status.rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
        let inputsHTML: String
        if let inputs = run.inputs, !inputs.isEmpty {
            let items = inputs.map { "\(escapeHTML($0.key))=\(escapeHTML($0.value))" }.joined(separator: ", ")
            inputsHTML = "<span class=\"run-inputs\">Inputs: \(items)</span>"
        } else {
            inputsHTML = ""
        }

        let completedCount = nodes.filter { $0.status == .completed }.count
        let totalCount = nodes.count

        let nodesHTML = nodes.map { renderNodeRow($0, runID: run.id) }.joined(separator: "\n")

        return """
        <div class="run-header">
            <div class="run-header-top">
                <a href="/runs" class="back-link" hx-get="/runs" hx-target="#content" hx-push-url="true">&larr; Back to runs</a>
                <div class="run-header-status">
                    <span class="status-badge \(statusClass)">\(statusLabel)</span>
                    <span class="run-time">Started \(relativeTime(run.createdAt))</span>
                </div>
            </div>
            <div class="run-header-detail">
                <span class="run-detail-name">\(escapeHTML(run.workflowName))</span>
                \(inputsHTML)
            </div>
        </div>
        <div class="nodes-section">
            <div class="nodes-header">Nodes (\(completedCount)/\(totalCount) completed)</div>
            <div class="nodes-list" id="nodes-list">
                \(nodesHTML)
            </div>
        </div>
        """
    }

    static func renderNodeRow(_ node: NodeExecution, runID: String) -> String {
        let statusIcon = nodeStatusIcon(node.status)
        let statusClass = nodeStatusCSSClass(node.status)
        let agentLabel = node.agent.map { "<span class=\"node-agent\">\(escapeHTML($0))</span>" } ?? ""
        let duration = formatNodeDuration(node)
        let isRunning = node.status == .running
        let expandedClass = isRunning ? " expanded" : ""

        var attemptInfo = ""
        if node.attempt > 1 || node.iteration > 1 {
            attemptInfo = "<span class=\"node-attempt\">attempt \(node.attempt)/iter \(node.iteration)</span>"
        }

        let errorHTML: String
        if let error = node.error {
            errorHTML = "<div class=\"node-error\">\(escapeHTML(error))</div>"
        } else {
            errorHTML = ""
        }

        return """
        <div class="node-row \(statusClass)\(expandedClass)" id="node-\(node.id)">
            <div class="node-row-header" onclick="toggleNode(this)">
                <div class="node-row-left">
                    <span class="node-icon">\(statusIcon)</span>
                    <span class="node-name">\(escapeHTML(node.nodeID))</span>
                    \(agentLabel)
                    \(attemptInfo)
                </div>
                <div class="node-row-right">
                    <span class="node-duration">\(duration)</span>
                    <span class="node-toggle">\(isRunning ? "▲" : "▼") logs</span>
                </div>
            </div>
            \(errorHTML)
            <div class="node-logs" id="logs-\(node.id)"
                 hx-get="/api/runs/\(runID)/nodes/\(node.nodeID)/logs?format=html"
                 hx-trigger="revealed"
                 hx-swap="innerHTML">
            </div>
        </div>
        """
    }

    // MARK: - Log Panel

    static func renderLogPanel(_ entries: [(stream: String, content: String, timestamp: Date)]) -> String {
        if entries.isEmpty {
            return "<div class=\"log-empty\">No logs available</div>"
        }
        let lines = entries.map { entry in
            let streamClass = entry.stream == "stderr" ? "log-stderr" : "log-stdout"
            return "<div class=\"log-line \(streamClass)\"><span class=\"log-stream\">[\(entry.stream)]</span> \(escapeHTML(entry.content))</div>"
        }.joined(separator: "\n")
        return "<div class=\"log-content\">\(lines)</div>"
    }

    // MARK: - Full Page Shell

    static func renderPageShell(title: String, content: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(title)) — orc monitor</title>
            <link rel="stylesheet" href="/styles.css">
            <script src="/htmx.min.js"></script>
        </head>
        <body hx-ext="sse" sse-connect="/api/events">
            <nav class="top-nav">
                <div class="nav-left">
                    <strong class="nav-logo">orc monitor</strong>
                    <a href="/runs" class="nav-link" hx-get="/runs" hx-target="#content" hx-push-url="true">Runs</a>
                </div>
                <div class="nav-right">
                    <span class="connection-dot" id="conn-dot"></span>
                    <span class="connection-label" id="conn-label">Connecting...</span>
                </div>
            </nav>
            <main id="content">
                \(content)
            </main>
            <script>
            function toggleNode(header) {
                const row = header.closest('.node-row');
                row.classList.toggle('expanded');
            }

            // SSE connection status
            document.body.addEventListener('htmx:sseOpen', function() {
                document.getElementById('conn-dot').className = 'connection-dot connected';
                document.getElementById('conn-label').textContent = 'Connected';
            });
            document.body.addEventListener('htmx:sseError', function() {
                document.getElementById('conn-dot').className = 'connection-dot disconnected';
                document.getElementById('conn-label').textContent = 'Disconnected';
            });
            document.body.addEventListener('htmx:sseClose', function() {
                document.getElementById('conn-dot').className = 'connection-dot disconnected';
                document.getElementById('conn-label').textContent = 'Disconnected';
            });
            </script>
        </body>
        </html>
        """
    }

    // MARK: - Runs Page

    static func renderRunsPage(_ runs: [Run], statusFilter: String?) -> String {
        let filters = ["all", "running", "failed", "completed", "awaiting_input", "cancelled", "pending"]
        let activeFilter = statusFilter ?? "all"
        let filterHTML = filters.map { filter in
            let label = filter.replacingOccurrences(of: "_", with: " ").capitalized
            let active = filter == activeFilter ? " active" : ""
            let url = filter == "all" ? "/runs" : "/runs?status=\(filter)"
            return "<a class=\"filter-tab\(active)\" href=\"\(url)\" hx-get=\"\(url)\" hx-target=\"#content\" hx-push-url=\"true\">\(label)</a>"
        }.joined(separator: "\n")

        let listHTML = renderRunsList(runs)

        return """
        <div class="runs-page">
            <div class="runs-header">
                <h2>Workflow Runs</h2>
                <div class="filter-tabs">
                    \(filterHTML)
                </div>
            </div>
            <div class="runs-list" id="runs-list"
                 sse-swap="run:created,run:updated"
                 hx-get="/runs?partial=true\(statusFilter.map { "&status=\($0)" } ?? "")"
                 hx-trigger="sse:run:created, sse:run:updated"
                 hx-swap="innerHTML">
                \(listHTML)
            </div>
        </div>
        """
    }

    // MARK: - Helpers

    static func statusCSSClass(_ status: RunStatus) -> String {
        switch status {
        case .pending: "status-pending"
        case .running: "status-running"
        case .awaitingInput: "status-awaiting"
        case .completed: "status-completed"
        case .failed: "status-failed"
        case .cancelled: "status-cancelled"
        }
    }

    static func nodeStatusCSSClass(_ status: NodeStatus) -> String {
        switch status {
        case .pending: "node-pending"
        case .running: "node-running"
        case .awaitingInput: "node-awaiting"
        case .completed: "node-completed"
        case .failed: "node-failed"
        case .skipped: "node-skipped"
        case .cancelled: "node-cancelled"
        }
    }

    static func nodeStatusIcon(_ status: NodeStatus) -> String {
        switch status {
        case .pending: "○"
        case .running: "⟳"
        case .awaitingInput: "⏸"
        case .completed: "✓"
        case .failed: "✗"
        case .skipped: "⊘"
        case .cancelled: "⊘"
        }
    }

    static func formatNodeDuration(_ node: NodeExecution) -> String {
        guard let start = node.startedAt else { return "" }
        let end = node.completedAt ?? Date()
        let seconds = end.timeIntervalSince(start)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        }
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
```

- [ ] **Step 3: Write TemplateRenderer tests**

Create `Orc/Core/Server/Tests/TemplateRendererTests.swift`:

```swift
import Testing
@testable import Server
import Models
import Foundation

@Suite("TemplateRenderer")
struct TemplateRendererTests {

    @Test("renderRunsList with empty array")
    func emptyRunsList() {
        let html = TemplateRenderer.renderRunsList([])
        #expect(html.contains("No workflow runs found"))
    }

    @Test("renderRunRow includes status badge and workflow name")
    func runRow() {
        let run = Run(
            id: "abc12345",
            workflowName: "deploy-pipeline",
            workflowFile: "deploy.yml",
            status: .running,
            workspacePath: "/tmp/ws",
            inputs: ["branch": "main"],
            output: nil,
            cleanupPolicy: .never,
            createdAt: Date(),
            updatedAt: Date()
        )
        let html = TemplateRenderer.renderRunRow(run)
        #expect(html.contains("RUNNING"))
        #expect(html.contains("deploy-pipeline"))
        #expect(html.contains("abc12345"))
        #expect(html.contains("/runs/abc12345"))
    }

    @Test("renderNodeRow shows status icon and agent")
    func nodeRow() {
        let node = NodeExecution(
            id: "n001",
            runID: "r001",
            nodeID: "lint",
            status: .completed,
            agent: "shell",
            attempt: 1,
            iteration: 1,
            prompt: nil,
            message: nil,
            output: "ok",
            error: nil,
            tmuxSession: nil,
            startedAt: Date().addingTimeInterval(-10),
            completedAt: Date()
        )
        let html = TemplateRenderer.renderNodeRow(node, runID: "r001")
        #expect(html.contains("✓"))
        #expect(html.contains("lint"))
        #expect(html.contains("shell"))
        #expect(html.contains("node-completed"))
    }

    @Test("renderNodeRow shows error for failed node")
    func failedNodeRow() {
        let node = NodeExecution(
            id: "n002",
            runID: "r001",
            nodeID: "build",
            status: .failed,
            agent: "shell",
            attempt: 2,
            iteration: 1,
            prompt: nil,
            message: nil,
            output: nil,
            error: "Exit code 1",
            tmuxSession: nil,
            startedAt: Date().addingTimeInterval(-30),
            completedAt: Date()
        )
        let html = TemplateRenderer.renderNodeRow(node, runID: "r001")
        #expect(html.contains("✗"))
        #expect(html.contains("Exit code 1"))
        #expect(html.contains("node-failed"))
        #expect(html.contains("attempt 2"))
    }

    @Test("renderLogPanel with entries")
    func logPanel() {
        let entries: [(stream: String, content: String, timestamp: Date)] = [
            (stream: "stdout", content: "Building...", timestamp: Date()),
            (stream: "stderr", content: "Warning: unused var", timestamp: Date()),
        ]
        let html = TemplateRenderer.renderLogPanel(entries)
        #expect(html.contains("Building..."))
        #expect(html.contains("Warning: unused var"))
        #expect(html.contains("log-stdout"))
        #expect(html.contains("log-stderr"))
    }

    @Test("renderLogPanel empty")
    func emptyLogPanel() {
        let html = TemplateRenderer.renderLogPanel([])
        #expect(html.contains("No logs available"))
    }

    @Test("renderPageShell includes nav and HTMX")
    func pageShell() {
        let html = TemplateRenderer.renderPageShell(title: "Runs", content: "<p>test</p>")
        #expect(html.contains("htmx.min.js"))
        #expect(html.contains("styles.css"))
        #expect(html.contains("orc monitor"))
        #expect(html.contains("<p>test</p>"))
        #expect(html.contains("sse-connect=\"/api/events\""))
    }

    @Test("escapeHTML escapes dangerous characters")
    func escapeHTML() {
        let result = TemplateRenderer.escapeHTML("<script>alert('xss')</script>")
        #expect(result == "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;")
    }

    @Test("renderRunsPage includes filter tabs")
    func runsPage() {
        let html = TemplateRenderer.renderRunsPage([], statusFilter: "running")
        #expect(html.contains("filter-tab active"))
        #expect(html.contains("Running"))
    }
}
```

- [ ] **Step 4: Build and run tests**

Run: `cd Orc && swift test --filter ServerTests`
Expected: all TemplateRenderer tests pass

- [ ] **Step 5: Commit**

```bash
git add Orc/Core/Server/Source/MonitorEvent.swift Orc/Core/Server/Source/TemplateRenderer.swift Orc/Core/Server/Tests/TemplateRendererTests.swift
git commit -m "[Claude] Add MonitorEvent model and TemplateRenderer with tests"
```

---

### Task 3: EventSource — Polling Engine for Changes

**Files:**
- Create: `Orc/Core/Server/Source/EventSource.swift`
- Create: `Orc/Core/Server/Tests/EventSourceTests.swift`

- [ ] **Step 1: Write EventProviding protocol and PollingEventSource**

Create `Orc/Core/Server/Source/EventSource.swift`:

```swift
import Engine
import Models
import Foundation
import Logging

protocol EventProviding: Sendable {
    func events() -> AsyncStream<MonitorEvent>
    func shutdown()
}

final class PollingEventSource: EventProviding, @unchecked Sendable {
    private let engine: any OrcEngineProviding
    private let pollInterval: Duration
    private let logger: Logger
    private let runIDFilter: String?

    private let lock = NSLock()
    private var lastRunStates: [String: RunStatus] = [:]
    private var lastNodeStates: [String: NodeStatus] = [:]
    private var knownRunIDs: Set<String> = []
    private var isShutdown = false

    init(
        engine: any OrcEngineProviding,
        pollInterval: Duration = .seconds(2),
        runIDFilter: String? = nil,
        logger: Logger = Logger(label: "orc.server.events")
    ) {
        self.engine = engine
        self.pollInterval = pollInterval
        self.runIDFilter = runIDFilter
        self.logger = logger
    }

    func events() -> AsyncStream<MonitorEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }

                // Initialize snapshot
                await self.initializeSnapshot()

                var heartbeatCounter = 0
                let heartbeatInterval = 15 // every 15 polls = 30s at 2s interval

                while !Task.isCancelled {
                    if self.checkShutdown() { break }

                    let events = await self.pollForChanges()
                    for event in events {
                        continuation.yield(event)
                    }

                    heartbeatCounter += 1
                    if heartbeatCounter >= heartbeatInterval {
                        continuation.yield(.heartbeat)
                        heartbeatCounter = 0
                    }

                    try? await Task.sleep(for: self.pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func shutdown() {
        lock.lock()
        isShutdown = true
        lock.unlock()
    }

    private func checkShutdown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShutdown
    }

    private func initializeSnapshot() async {
        do {
            let runs = try await engine.listRuns(status: nil)
            let filtered = filterRuns(runs)
            lock.lock()
            for run in filtered {
                lastRunStates[run.id] = run.status
                knownRunIDs.insert(run.id)
            }
            lock.unlock()

            for run in filtered where run.status == .running || run.status == .awaitingInput {
                let nodes = try await engine.getNodeExecutions(runID: run.id, nodeID: nil)
                lock.lock()
                for node in nodes {
                    lastNodeStates[node.id] = node.status
                }
                lock.unlock()
            }
        } catch {
            logger.error("Failed to initialize event source snapshot: \(error)")
        }
    }

    private func pollForChanges() async -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        do {
            let runs = try await engine.listRuns(status: nil)
            let filtered = filterRuns(runs)

            lock.lock()
            let previousRunStates = lastRunStates
            let previousKnownIDs = knownRunIDs
            lock.unlock()

            for run in filtered {
                if !previousKnownIDs.contains(run.id) {
                    events.append(.runCreated(run))
                    lock.lock()
                    knownRunIDs.insert(run.id)
                    lastRunStates[run.id] = run.status
                    lock.unlock()
                } else if previousRunStates[run.id] != run.status {
                    events.append(.runUpdated(run))
                    lock.lock()
                    lastRunStates[run.id] = run.status
                    lock.unlock()
                }
            }

            // Poll node executions for active runs
            let activeRuns = filtered.filter { $0.status == .running || $0.status == .awaitingInput }
            for run in activeRuns {
                let nodes = try await engine.getNodeExecutions(runID: run.id, nodeID: nil)
                lock.lock()
                let previousNodeStates = lastNodeStates
                lock.unlock()

                for node in nodes {
                    if previousNodeStates[node.id] != node.status {
                        events.append(.nodeUpdated(node))
                        lock.lock()
                        lastNodeStates[node.id] = node.status
                        lock.unlock()
                    }
                }
            }
        } catch {
            logger.error("Failed to poll for changes: \(error)")
        }
        return events
    }

    private func filterRuns(_ runs: [Run]) -> [Run] {
        if let filter = runIDFilter {
            return runs.filter { $0.id == filter }
        }
        return runs
    }
}
```

- [ ] **Step 2: Write EventSource tests**

Create `Orc/Core/Server/Tests/EventSourceTests.swift`:

```swift
import Testing
@testable import Server
import Models
import Foundation

// Minimal mock for testing EventSource
private final class MockEventEngine: OrcEngineProviding, @unchecked Sendable {
    var listRunsHandler: ((RunStatus?) async throws -> [Run])?
    var getNodeExecutionsHandler: ((String, String?) async throws -> [NodeExecution])?

    var basePath: String { "/tmp" }

    func listRuns(status: RunStatus?) async throws -> [Run] {
        try await listRunsHandler?(status) ?? []
    }
    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] {
        try await getNodeExecutionsHandler?(runID, nodeID) ?? []
    }

    // Stubs for unused protocol methods
    func start(workflowFile: String, inputs: [String: String], maxParallelNodes: Int?) async throws -> Run { fatalError() }
    func resume(runID: String) async throws -> Run { fatalError() }
    func cancel(runID: String) async throws { fatalError() }
    func respond(runID: String, nodeID: String, response: String) async throws { fatalError() }
    func getStatus(runID: String) async throws -> Run? { fatalError() }
    func getLogs(runID: String, nodeID: String?, attempt: Int?, iteration: Int?) async throws -> [LogEntry] { fatalError() }
    func getStats() async throws -> [RunStats] { fatalError() }
    func catalog() async throws -> Catalog { fatalError() }
    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult) { fatalError() }
    func getConfigValue(key: String) async throws -> String? { fatalError() }
    func setConfigValue(key: String, value: String) async throws { fatalError() }
    func unsetConfigValue(key: String) async throws { fatalError() }
    func loadConfig() async throws -> OrcConfig { fatalError() }
    func cleanupWorkspace(runID: String) async throws { fatalError() }
    func purge(olderThan: Date?, status: RunStatus?) async throws { fatalError() }
}

@Suite("PollingEventSource")
struct EventSourceTests {

    @Test("detects new run as run:created")
    func detectsNewRun() async {
        let mock = MockEventEngine()
        var callCount = 0

        let run = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .running, workspacePath: "/tmp", inputs: nil,
            output: nil, cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )

        mock.listRunsHandler = { _ in
            callCount += 1
            // First call (init): empty. Second call (poll): has run.
            return callCount <= 1 ? [] : [run]
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let source = PollingEventSource(engine: mock, pollInterval: .milliseconds(50))
        var collected: [MonitorEvent] = []

        for await event in source.events() {
            collected.append(event)
            if case .runCreated = event { break }
            if collected.count > 20 { break } // safety limit
        }
        source.shutdown()

        let hasCreated = collected.contains { if case .runCreated = $0 { return true }; return false }
        #expect(hasCreated)
    }

    @Test("detects run status change as run:updated")
    func detectsRunStatusChange() async {
        let mock = MockEventEngine()
        var callCount = 0

        let runningRun = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .running, workspacePath: "/tmp", inputs: nil,
            output: nil, cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )
        let completedRun = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .completed, workspacePath: "/tmp", inputs: nil,
            output: "done", cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )

        mock.listRunsHandler = { _ in
            callCount += 1
            return callCount <= 1 ? [runningRun] : [completedRun]
        }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        let source = PollingEventSource(engine: mock, pollInterval: .milliseconds(50))
        var collected: [MonitorEvent] = []

        for await event in source.events() {
            collected.append(event)
            if case .runUpdated = event { break }
            if collected.count > 20 { break }
        }
        source.shutdown()

        let hasUpdated = collected.contains { if case .runUpdated = $0 { return true }; return false }
        #expect(hasUpdated)
    }

    @Test("emits heartbeat")
    func emitsHeartbeat() async {
        let mock = MockEventEngine()
        mock.listRunsHandler = { _ in [] }
        mock.getNodeExecutionsHandler = { _, _ in [] }

        // Use a very short poll interval and low heartbeat threshold for testing
        let source = PollingEventSource(engine: mock, pollInterval: .milliseconds(10))
        var collected: [MonitorEvent] = []

        for await event in source.events() {
            collected.append(event)
            if case .heartbeat = event { break }
            if collected.count > 50 { break }
        }
        source.shutdown()

        let hasHeartbeat = collected.contains { if case .heartbeat = $0 { return true }; return false }
        #expect(hasHeartbeat)
    }
}
```

- [ ] **Step 3: Build and run tests**

Run: `cd Orc && swift test --filter ServerTests`
Expected: EventSource tests pass

- [ ] **Step 4: Commit**

```bash
git add Orc/Core/Server/Source/EventSource.swift Orc/Core/Server/Tests/EventSourceTests.swift
git commit -m "[Claude] Add EventProviding protocol and PollingEventSource with tests"
```

---

### Task 4: REST API Routes

**Files:**
- Create: `Orc/Core/Server/Source/HealthRoutes.swift`
- Create: `Orc/Core/Server/Source/RunRoutes.swift`
- Create: `Orc/Core/Server/Source/LogRoutes.swift`
- Create: `Orc/Core/Server/Source/StatsRoutes.swift`
- Create: `Orc/Core/Server/Source/CatalogRoutes.swift`
- Create: `Orc/Core/Server/Source/Routes.swift`

- [ ] **Step 1: Create HealthRoutes**

Create `Orc/Core/Server/Source/HealthRoutes.swift`:

```swift
import Hummingbird

struct HealthResponse: ResponseCodable {
    let status: String
}

func addHealthRoutes(to group: RouterGroup<BasicRequestContext>) {
    group.get("health") { _, _ -> HealthResponse in
        HealthResponse(status: "ok")
    }
}
```

- [ ] **Step 2: Create RunRoutes**

Create `Orc/Core/Server/Source/RunRoutes.swift`:

```swift
import Hummingbird
import Engine
import Models

func addRunRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("runs") { request, _ -> Response in
        let statusParam: String? = request.uri.queryParameters["status"].map(String.init)
        let status: RunStatus? = statusParam.flatMap { RunStatus(rawValue: $0) }
        let runs = try await engine.listRuns(status: status)
        return try jsonResponse(runs)
    }

    group.get("runs/:id") { _, context -> Response in
        let id = try context.parameters.require("id")
        guard let run = try await engine.getStatus(runID: id) else {
            throw HTTPError(.notFound, message: "Run not found")
        }
        return try jsonResponse(run)
    }

    group.get("runs/:id/nodes") { _, context -> Response in
        let id = try context.parameters.require("id")
        let nodes = try await engine.getNodeExecutions(runID: id, nodeID: nil)
        return try jsonResponse(nodes)
    }
}
```

- [ ] **Step 3: Create LogRoutes**

Create `Orc/Core/Server/Source/LogRoutes.swift`:

```swift
import Hummingbird
import Engine
import Models
import Foundation

struct LogContent: Encodable {
    let stream: String
    let content: String
    let timestamp: Date
}

func addLogRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("runs/:runID/nodes/:nodeID/logs") { request, context -> Response in
        let runID = try context.parameters.require("runID")
        let nodeID = try context.parameters.require("nodeID")
        let attemptParam: String? = request.uri.queryParameters["attempt"].map(String.init)
        let iterationParam: String? = request.uri.queryParameters["iteration"].map(String.init)
        let attempt = attemptParam.flatMap(Int.init)
        let iteration = iterationParam.flatMap(Int.init)
        let formatParam: String? = request.uri.queryParameters["format"].map(String.init)

        let entries = try await engine.getLogs(
            runID: runID,
            nodeID: nodeID,
            attempt: attempt,
            iteration: iteration
        )

        // Read file contents for each log entry
        let logContents: [(stream: String, content: String, timestamp: Date)] = entries.compactMap { entry in
            guard let data = FileManager.default.contents(atPath: entry.filePath),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            return (stream: entry.stream.rawValue, content: content, timestamp: entry.timestamp)
        }

        if formatParam == "html" {
            let html = TemplateRenderer.renderLogPanel(logContents)
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: .init(string: html))
            )
        }

        let response = logContents.map { LogContent(stream: $0.stream, content: $0.content, timestamp: $0.timestamp) }
        return try jsonResponse(response)
    }
}
```

- [ ] **Step 4: Create StatsRoutes**

Create `Orc/Core/Server/Source/StatsRoutes.swift`:

```swift
import Hummingbird
import Engine
import Models

func addStatsRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("stats") { _, _ -> Response in
        let stats = try await engine.getStats()
        return try jsonResponse(stats)
    }
}
```

- [ ] **Step 5: Create CatalogRoutes**

Create `Orc/Core/Server/Source/CatalogRoutes.swift`:

```swift
import Hummingbird
import Engine
import Models

// NOTE: Catalog and CatalogEntry may not conform to Codable.
// If they don't, add a local CatalogResponse DTO here.
struct CatalogResponse: Encodable {
    struct Entry: Encodable {
        let name: String
        let description: String?
        let fileName: String
    }
    let workflows: [Entry]
    let evaluators: [Entry]
}

func addCatalogRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("catalog") { _, _ -> Response in
        let catalog = try await engine.catalog()
        let response = CatalogResponse(
            workflows: catalog.workflows.map { .init(name: $0.name, description: $0.description, fileName: $0.fileName) },
            evaluators: catalog.evaluators.map { .init(name: $0.name, description: $0.description, fileName: $0.fileName) }
        )
        return try jsonResponse(response)
    }
}
```

- [ ] **Step 6: Create Routes.swift with JSON helper and route registration**

Create `Orc/Core/Server/Source/Routes.swift`:

```swift
import Hummingbird
import Engine
import Models
import Foundation

func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: .init(data: data))
    )
}

func registerAPIRoutes(on router: Router<BasicRequestContext>, engine: any OrcEngineProviding) {
    let api = router.group("api")
    addHealthRoutes(to: api)
    addRunRoutes(to: api, engine: engine)
    addLogRoutes(to: api, engine: engine)
    addStatsRoutes(to: api, engine: engine)
    addCatalogRoutes(to: api, engine: engine)
}
```

- [ ] **Step 7: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 8: Commit**

```bash
git add Orc/Core/Server/Source/HealthRoutes.swift Orc/Core/Server/Source/RunRoutes.swift Orc/Core/Server/Source/LogRoutes.swift Orc/Core/Server/Source/StatsRoutes.swift Orc/Core/Server/Source/CatalogRoutes.swift Orc/Core/Server/Source/Routes.swift
git commit -m "[Claude] Add REST API route handlers for runs, logs, stats, catalog"
```

---

### Task 5: SSE Event Route

**Files:**
- Create: `Orc/Core/Server/Source/EventRoutes.swift`

- [ ] **Step 1: Create EventRoutes**

Create `Orc/Core/Server/Source/EventRoutes.swift`:

```swift
import Hummingbird
import Engine
import Foundation

func addEventRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("events") { request, _ -> Response in
        let runIDFilter: String? = request.uri.queryParameters["runID"].map(String.init)

        let source = PollingEventSource(engine: engine, runIDFilter: runIDFilter)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
                .init("Connection")!: "keep-alive",
            ],
            body: ResponseBody { writer in
                try await withGracefulShutdownHandler {
                    for await event in source.events() {
                        try Task.checkCancellation()
                        let formatted = try event.sseFormatted(encoder: encoder)
                        try await writer.write(.init(string: formatted))
                    }
                } onGracefulShutdown: {
                    source.shutdown()
                }
                try await writer.finish(nil)
            }
        )
    }
}
```

- [ ] **Step 2: Register event routes in Routes.swift**

Update `Orc/Core/Server/Source/Routes.swift` — add this line inside `registerAPIRoutes`:

```swift
addEventRoutes(to: api, engine: engine)
```

The function becomes:

```swift
func registerAPIRoutes(on router: Router<BasicRequestContext>, engine: any OrcEngineProviding) {
    let api = router.group("api")
    addHealthRoutes(to: api)
    addRunRoutes(to: api, engine: engine)
    addLogRoutes(to: api, engine: engine)
    addStatsRoutes(to: api, engine: engine)
    addCatalogRoutes(to: api, engine: engine)
    addEventRoutes(to: api, engine: engine)
}
```

- [ ] **Step 3: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 4: Commit**

```bash
git add Orc/Core/Server/Source/EventRoutes.swift Orc/Core/Server/Source/Routes.swift
git commit -m "[Claude] Add SSE event streaming route"
```

---

### Task 6: Page Routes (Server-Rendered HTML)

**Files:**
- Create: `Orc/Core/Server/Source/PageRoutes.swift`

- [ ] **Step 1: Create PageRoutes**

Create `Orc/Core/Server/Source/PageRoutes.swift`:

```swift
import Hummingbird
import Engine
import Models

func htmlResponse(_ html: String) -> Response {
    Response(
        status: .ok,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: .init(byteBuffer: .init(string: html))
    )
}

func registerPageRoutes(on router: Router<BasicRequestContext>, engine: any OrcEngineProviding) {
    router.get("/") { _, _ -> Response in
        Response(status: .seeOther, headers: [.location: "/runs"])
    }

    router.get("runs") { request, _ -> Response in
        let statusParam: String? = request.uri.queryParameters["status"].map(String.init)
        let partialParam: String? = request.uri.queryParameters["partial"].map(String.init)
        let status: RunStatus? = statusParam.flatMap { RunStatus(rawValue: $0) }
        let runs = try await engine.listRuns(status: status)

        if partialParam == "true" {
            // HTMX partial: just the runs list
            return htmlResponse(TemplateRenderer.renderRunsList(runs))
        }

        let content = TemplateRenderer.renderRunsPage(runs, statusFilter: statusParam)
        let page = TemplateRenderer.renderPageShell(title: "Runs", content: content)
        return htmlResponse(page)
    }

    router.get("runs/:id") { _, context -> Response in
        let id = try context.parameters.require("id")
        guard let run = try await engine.getStatus(runID: id) else {
            throw HTTPError(.notFound, message: "Run not found")
        }
        let nodes = try await engine.getNodeExecutions(runID: id, nodeID: nil)
        let content = TemplateRenderer.renderRunDetail(run, nodes: nodes)
        let page = TemplateRenderer.renderPageShell(title: run.workflowName, content: content)
        return htmlResponse(page)
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 3: Commit**

```bash
git add Orc/Core/Server/Source/PageRoutes.swift
git commit -m "[Claude] Add server-rendered HTML page routes"
```

---

### Task 7: Static Assets (CSS, HTMX, HTML)

**Files:**
- Create: `Orc/Core/Server/Resources/styles.css`
- Create: `Orc/Core/Server/Resources/htmx.min.js` (download vendored)
- Replace: `Orc/Core/Server/Resources/index.html` (placeholder from Task 1)

- [ ] **Step 1: Download HTMX**

```bash
curl -L -o Orc/Core/Server/Resources/htmx.min.js https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js
```

- [ ] **Step 2: Create styles.css**

Create `Orc/Core/Server/Resources/styles.css` with the dark theme:

```css
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background: #0d1117;
    color: #e0e0e0;
    line-height: 1.5;
}

/* Nav */
.top-nav {
    background: #1a1a2e;
    padding: 10px 20px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid #333;
    position: sticky;
    top: 0;
    z-index: 100;
}
.nav-left { display: flex; align-items: center; gap: 16px; }
.nav-logo { color: #fff; font-size: 15px; }
.nav-link {
    color: #aaa;
    text-decoration: none;
    padding: 4px 10px;
    border-radius: 4px;
    background: #252540;
    font-size: 13px;
}
.nav-link:hover { color: #fff; background: #333355; }
.nav-right { display: flex; align-items: center; gap: 8px; }
.connection-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: #666;
    display: inline-block;
}
.connection-dot.connected { background: #4caf50; }
.connection-dot.disconnected { background: #f44336; }
.connection-label { color: #888; font-size: 12px; }

/* Main */
main { padding: 20px; max-width: 1200px; margin: 0 auto; }

/* Runs page */
.runs-page {}
.runs-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
}
.runs-header h2 { color: #fff; font-size: 16px; font-weight: 600; }
.filter-tabs { display: flex; gap: 6px; }
.filter-tab {
    padding: 4px 10px;
    border-radius: 4px;
    font-size: 12px;
    color: #888;
    border: 1px solid #333;
    background: transparent;
    text-decoration: none;
    cursor: pointer;
}
.filter-tab:hover { color: #ccc; border-color: #555; }
.filter-tab.active { background: #1a1a2e; color: #4caf50; border-color: #4caf50; }

/* Run list */
.runs-list {
    border: 1px solid #222;
    border-radius: 6px;
    overflow: hidden;
}
.run-row {
    padding: 10px 16px;
    background: #111820;
    border-bottom: 1px solid #222;
    display: flex;
    justify-content: space-between;
    align-items: center;
    cursor: pointer;
    text-decoration: none;
    color: inherit;
    transition: background 0.15s;
}
.run-row:hover { background: #161e28; }
.run-row:last-child { border-bottom: none; }
.run-row-left { display: flex; align-items: center; gap: 10px; }
.run-row-right { display: flex; align-items: center; gap: 16px; }
.run-name { color: #fff; font-size: 13px; font-weight: 500; }
.run-id { color: #666; font-size: 11px; font-family: monospace; }
.run-time { color: #666; font-size: 11px; }
.run-inputs { color: #666; font-size: 12px; }

/* Status badges */
.status-badge {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.5px;
}
.status-running { color: #ffa726; }
.status-completed { color: #4caf50; }
.status-failed { color: #f44336; }
.status-awaiting { color: #42a5f5; }
.status-pending { color: #888; }
.status-cancelled { color: #888; }

/* Run detail */
.run-header {
    background: #111820;
    border: 1px solid #222;
    border-radius: 6px;
    padding: 14px 18px;
    margin-bottom: 16px;
}
.run-header-top {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
}
.run-header-status { display: flex; align-items: center; gap: 10px; }
.back-link {
    color: #666;
    font-size: 12px;
    text-decoration: none;
    cursor: pointer;
}
.back-link:hover { color: #aaa; }
.run-header-detail { display: flex; align-items: center; gap: 16px; }
.run-detail-name { color: #fff; font-size: 16px; font-weight: 600; }

/* Nodes */
.nodes-section {}
.nodes-header { color: #888; font-size: 12px; margin-bottom: 8px; }
.nodes-list { display: flex; flex-direction: column; gap: 6px; }

.node-row {
    border: 1px solid #222;
    border-radius: 4px;
    overflow: hidden;
}
.node-row.node-running { border-color: #ffa726; }
.node-row.node-failed { border-color: #f44336; }

.node-row-header {
    padding: 8px 14px;
    background: #111820;
    display: flex;
    justify-content: space-between;
    align-items: center;
    cursor: pointer;
    transition: background 0.15s;
}
.node-row-header:hover { background: #161e28; }
.node-running .node-row-header { background: #1a1510; }
.node-failed .node-row-header { background: #1a1212; }

.node-row-left { display: flex; align-items: center; gap: 8px; }
.node-row-right { display: flex; align-items: center; gap: 12px; }
.node-icon { font-size: 14px; }
.node-completed .node-icon { color: #4caf50; }
.node-running .node-icon { color: #ffa726; }
.node-failed .node-icon { color: #f44336; }
.node-awaiting .node-icon { color: #42a5f5; }
.node-pending .node-icon { color: #666; }
.node-skipped .node-icon { color: #666; }
.node-cancelled .node-icon { color: #666; }
.node-name { color: #ccc; font-size: 13px; }
.node-running .node-name { color: #fff; font-weight: 500; }
.node-agent { color: #666; font-size: 11px; }
.node-attempt { color: #555; font-size: 11px; }
.node-duration { color: #888; font-size: 11px; }
.node-toggle { color: #555; font-size: 11px; }

.node-error {
    padding: 6px 14px;
    background: #1a1212;
    color: #f44336;
    font-size: 12px;
    font-family: monospace;
}

/* Logs (collapsed by default) */
.node-logs {
    display: none;
    padding: 10px 14px;
    background: #0a0e14;
    font-family: monospace;
    font-size: 11px;
    line-height: 1.6;
    max-height: 300px;
    overflow-y: auto;
}
.node-row.expanded .node-logs { display: block; }
.log-content {}
.log-line { color: #888; white-space: pre-wrap; word-break: break-all; }
.log-stream { color: #555; }
.log-stderr { color: #f4433688; }
.log-empty { color: #555; font-style: italic; }

/* Empty state */
.empty-state {
    padding: 40px;
    text-align: center;
    color: #666;
    font-size: 14px;
}

/* Scrollbar */
::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: #555; }
```

- [ ] **Step 3: Remove placeholder index.html**

The page shell is rendered dynamically by `TemplateRenderer.renderPageShell()`, so `index.html` is no longer needed as the entry point. However, SPM requires at least one resource file. The `styles.css` and `htmx.min.js` serve as the bundled resources. Delete the placeholder `index.html`:

```bash
rm Orc/Core/Server/Resources/index.html
```

- [ ] **Step 4: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 5: Commit**

```bash
git add Orc/Core/Server/Resources/
git commit -m "[Claude] Add static assets: dark theme CSS and vendored HTMX"
```

---

### Task 8: MonitorServer Actor

**Files:**
- Create: `Orc/Core/Server/Source/MonitorServer.swift`

- [ ] **Step 1: Write MonitorServer**

Create `Orc/Core/Server/Source/MonitorServer.swift`:

```swift
import Hummingbird
import Engine
import Models
import Foundation
import Logging

public actor MonitorServer {
    private let engine: any OrcEngineProviding
    private let host: String
    private let port: Int
    private let logger: Logger
    private var serverTask: Task<Void, any Error>?

    public nonisolated var url: URL {
        URL(string: "http://\(host == "0.0.0.0" ? "localhost" : host):\(port)")!
    }

    public init(engine: any OrcEngineProviding, host: String = "127.0.0.1", port: Int = 9621) {
        self.engine = engine
        self.host = host
        self.port = port
        self.logger = Logger(label: "orc.server")
    }

    public func start() async throws {
        let router = Router()

        // Static file serving from bundled resources
        let resourcePath = Bundle.module.resourcePath!
        router.addMiddleware {
            FileMiddleware(resourcePath)
        }

        // Register routes
        registerAPIRoutes(on: router, engine: engine)
        registerPageRoutes(on: router, engine: engine)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port)),
            logger: logger
        )

        logger.info("Starting orc monitor at \(url.absoluteString)")

        serverTask = Task {
            try await app.runService()
        }

        // Give the server a moment to bind
        try await Task.sleep(for: .milliseconds(200))
    }

    public func stop() async {
        serverTask?.cancel()
        serverTask = nil
        logger.info("orc monitor stopped")
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 3: Commit**

```bash
git add Orc/Core/Server/Source/MonitorServer.swift
git commit -m "[Claude] Add MonitorServer actor for server lifecycle"
```

---

### Task 9: MonitorCommand (`orc monitor`)

**Files:**
- Create: `Orc/CLI/Source/Commands/MonitorCommand.swift`
- Modify: `Orc/CLI/Source/Commands/OrcCommand.swift`

- [ ] **Step 1: Create MonitorCommand**

Create `Orc/CLI/Source/Commands/MonitorCommand.swift`:

```swift
import ArgumentParser
import Engine
import Server
import Foundation

struct MonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Start a local web server for monitoring workflow runs"
    )

    @Option(name: .long, help: "Port to bind (default: 9621)")
    var port: Int = 9621

    @Option(name: .long, help: "Host to bind (default: 127.0.0.1)")
    var host: String = "127.0.0.1"

    @Flag(name: .long, help: "Don't open browser automatically")
    var noOpen: Bool = false

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        let server = MonitorServer(engine: engine, host: host, port: port)

        do {
            try await server.start()
        } catch {
            Format.printError("Error: Failed to start monitor server on \(host):\(port) — \(error)")
            throw ExitCode.failure
        }

        let url = server.url
        print("orc monitor running at \(url.absoluteString)")
        print("Press Ctrl+C to stop")

        if !noOpen {
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            try? process.run()
            #elseif os(Linux)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
            process.arguments = [url.absoluteString]
            try? process.run()
            #endif
        }

        // Block until cancelled (Ctrl+C)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler {
                signalSource.cancel()
                continuation.resume()
            }
            signalSource.resume()
        }

        await server.stop()
        print("\norc monitor stopped")
    }
}
```

- [ ] **Step 2: Register MonitorCommand in OrcCommand**

In `Orc/CLI/Source/Commands/OrcCommand.swift`, add `MonitorCommand.self` to the `subcommands` array:

```swift
subcommands: [
    InitCommand.self, ValidateCommand.self, StartCommand.self,
    ResumeCommand.self, CatalogCommand.self, ListCommand.self,
    StatusCommand.self, AttachCommand.self, RespondCommand.self,
    LogsCommand.self, CancelCommand.self, CleanupCommand.self,
    PurgeCommand.self, StatsCommand.self, ConfigCommand.self,
    VersionCommand.self, MonitorCommand.self,
]
```

- [ ] **Step 3: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 4: Smoke test**

```bash
# Initialize a test project if needed
mkdir -p /tmp/orc-test && cd /tmp/orc-test
/path/to/PreBuild/orc init 2>/dev/null || true

# Run monitor with --no-open and kill after 2 seconds
timeout 3 /path/to/PreBuild/orc monitor --no-open || true
```

Expected: prints "orc monitor running at http://127.0.0.1:9621" before timeout kills it

- [ ] **Step 5: Commit**

```bash
git add Orc/CLI/Source/Commands/MonitorCommand.swift Orc/CLI/Source/Commands/OrcCommand.swift
git commit -m "[Claude] Add orc monitor CLI command"
```

---

### Task 10: StartCommand `--monitor` Flag

**Files:**
- Modify: `Orc/CLI/Source/Commands/StartCommand.swift`

- [ ] **Step 1: Add --monitor flag to StartCommand**

Add this property alongside the other flags in `StartCommand`:

```swift
@Flag(name: .long, help: "Open browser monitor for this run")
var monitor: Bool = false
```

- [ ] **Step 2: Add monitor logic to execute method**

In the `execute(engine:)` method, after the engine is created but before calling `engine.start()`, add server startup logic. After `engine.start()` returns the run, open the browser to the run detail page. After the workflow completes, keep the server alive briefly.

Add `import Server` at the top of the file.

In the `execute` method, wrap the existing logic:

Before calling `engine.start(...)`:

```swift
var monitorServer: MonitorServer?
if monitor {
    let server = MonitorServer(engine: engine)
    do {
        try await server.start()
        monitorServer = server
    } catch {
        Format.printError("Warning: Could not start monitor server — \(error)")
    }
}
```

After `engine.start(...)` returns the run (and before printing results), add:

```swift
if let server = monitorServer {
    let runURL = server.url.appendingPathComponent("runs/\(run.id)")
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [runURL.absoluteString]
    try? process.run()
    #elseif os(Linux)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
    process.arguments = [runURL.absoluteString]
    try? process.run()
    #endif
}
```

After the workflow completes and results are printed, keep the server alive briefly:

```swift
if let server = monitorServer {
    print("Monitor available at \(server.url.absoluteString)/runs/\(run.id) — shutting down in 30s...")
    try? await Task.sleep(for: .seconds(30))
    await server.stop()
}
```

- [ ] **Step 3: Verify build compiles**

Run: `bash Scripts/build.sh`
Expected: build succeeds

- [ ] **Step 4: Commit**

```bash
git add Orc/CLI/Source/Commands/StartCommand.swift
git commit -m "[Claude] Add --monitor flag to orc start command"
```

---

### Task 11: Route Tests

**Files:**
- Create: `Orc/Core/Server/Tests/RouteTests.swift`

- [ ] **Step 1: Write route tests**

Create `Orc/Core/Server/Tests/RouteTests.swift`:

```swift
import Testing
@testable import Server
import Hummingbird
import HummingbirdTesting
import Models
import Engine
import Foundation

private final class MockRouteEngine: OrcEngineProviding, @unchecked Sendable {
    var listRunsResult: [Run] = []
    var getStatusResult: Run?
    var getNodeExecutionsResult: [NodeExecution] = []
    var getLogsResult: [LogEntry] = []
    var getStatsResult: [RunStats] = []
    var catalogResult: Catalog = Catalog(workflows: [], evaluators: [])

    var basePath: String { "/tmp" }

    func listRuns(status: RunStatus?) async throws -> [Run] {
        if let status {
            return listRunsResult.filter { $0.status == status }
        }
        return listRunsResult
    }
    func getStatus(runID: String) async throws -> Run? { getStatusResult }
    func getNodeExecutions(runID: String, nodeID: String?) async throws -> [NodeExecution] { getNodeExecutionsResult }
    func getLogs(runID: String, nodeID: String?, attempt: Int?, iteration: Int?) async throws -> [LogEntry] { getLogsResult }
    func getStats() async throws -> [RunStats] { getStatsResult }
    func catalog() async throws -> Catalog { catalogResult }

    // Unused stubs
    func start(workflowFile: String, inputs: [String: String], maxParallelNodes: Int?) async throws -> Run { fatalError() }
    func resume(runID: String) async throws -> Run { fatalError() }
    func cancel(runID: String) async throws { fatalError() }
    func respond(runID: String, nodeID: String, response: String) async throws { fatalError() }
    func validate(workflowFile: String) async throws -> (Workflow, ValidationResult) { fatalError() }
    func getConfigValue(key: String) async throws -> String? { fatalError() }
    func setConfigValue(key: String, value: String) async throws { fatalError() }
    func unsetConfigValue(key: String) async throws { fatalError() }
    func loadConfig() async throws -> OrcConfig { fatalError() }
    func cleanupWorkspace(runID: String) async throws { fatalError() }
    func purge(olderThan: Date?, status: RunStatus?) async throws { fatalError() }
}

private func buildTestApp(engine: MockRouteEngine) -> some ApplicationProtocol {
    let router = Router()
    registerAPIRoutes(on: router, engine: engine)
    return Application(router: router)
}

@Suite("API Routes")
struct RouteTests {

    @Test("GET /api/health returns ok")
    func healthCheck() async throws {
        let engine = MockRouteEngine()
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("ok"))
            }
        }
    }

    @Test("GET /api/runs returns runs list")
    func listRuns() async throws {
        let engine = MockRouteEngine()
        engine.listRunsResult = [
            Run(id: "r001", workflowName: "test", workflowFile: "test.yml",
                status: .running, workspacePath: "/tmp", inputs: nil,
                output: nil, cleanupPolicy: .never,
                createdAt: Date(), updatedAt: Date())
        ]
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("r001"))
                #expect(body.contains("test"))
            }
        }
    }

    @Test("GET /api/runs/:id returns 404 for missing run")
    func missingRun() async throws {
        let engine = MockRouteEngine()
        engine.getStatusResult = nil
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs/nonexistent", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("GET /api/runs/:id returns run detail")
    func runDetail() async throws {
        let engine = MockRouteEngine()
        engine.getStatusResult = Run(
            id: "r001", workflowName: "test", workflowFile: "test.yml",
            status: .completed, workspacePath: "/tmp", inputs: nil,
            output: "done", cleanupPolicy: .never,
            createdAt: Date(), updatedAt: Date()
        )
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs/r001", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("r001"))
                #expect(body.contains("completed"))
            }
        }
    }

    @Test("GET /api/runs/:id/nodes returns node executions")
    func nodeExecutions() async throws {
        let engine = MockRouteEngine()
        engine.getNodeExecutionsResult = [
            NodeExecution(
                id: "n001", runID: "r001", nodeID: "lint",
                status: .completed, agent: "shell",
                attempt: 1, iteration: 1,
                prompt: nil, message: nil, output: "ok", error: nil,
                tmuxSession: nil,
                startedAt: Date(), completedAt: Date()
            )
        ]
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/runs/r001/nodes", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("lint"))
                #expect(body.contains("completed"))
            }
        }
    }

    @Test("GET /api/stats returns stats")
    func stats() async throws {
        let engine = MockRouteEngine()
        engine.getStatsResult = [
            RunStats(id: 1, runID: "r001", workflowName: "test",
                     status: .completed, nodeCount: 3,
                     durationSeconds: 45.2, completedAt: Date())
        ]
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/stats", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("test"))
                #expect(body.contains("45.2"))
            }
        }
    }

    @Test("GET /api/catalog returns catalog")
    func catalog() async throws {
        let engine = MockRouteEngine()
        engine.catalogResult = Catalog(
            workflows: [CatalogEntry(name: "deploy", description: "Deploy pipeline", fileName: "deploy.yml")],
            evaluators: []
        )
        let app = buildTestApp(engine: engine)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/catalog", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("deploy"))
            }
        }
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `cd Orc && swift test --filter ServerTests`
Expected: all route tests + template tests + event source tests pass

- [ ] **Step 3: Commit**

```bash
git add Orc/Core/Server/Tests/RouteTests.swift
git commit -m "[Claude] Add API route tests with mock engine"
```

---

### Task 12: Final Build Verification and Smoke Test

**Files:** None new — verification only.

- [ ] **Step 1: Full build**

Run: `bash Scripts/build.sh`
Expected: clean build, no warnings

- [ ] **Step 2: Run all tests**

Run: `cd Orc && swift test`
Expected: all tests pass (existing + new Server tests)

- [ ] **Step 3: Smoke test orc monitor**

```bash
mkdir -p /tmp/orc-smoke && cd /tmp/orc-smoke
PreBuild/orc init 2>/dev/null || true
timeout 3 PreBuild/orc monitor --no-open 2>&1 || true
```

Expected: prints server URL before timeout

- [ ] **Step 4: Smoke test curl endpoints**

In a separate terminal, while the server runs:

```bash
curl -s http://127.0.0.1:9621/api/health | grep ok
curl -s http://127.0.0.1:9621/api/runs | head -c 100
curl -s http://127.0.0.1:9621/runs | head -c 200
```

Expected: health returns `{"status":"ok"}`, runs returns JSON array, /runs returns HTML

- [ ] **Step 5: Commit (if any fixes were needed)**

```bash
git add -A
git commit -m "[Claude] Fix issues found during smoke testing"
```
