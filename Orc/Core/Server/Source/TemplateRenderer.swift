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
        let filterHTML = filters.map { filter -> String in
            let label = filter.replacingOccurrences(of: "_", with: " ").capitalized
            let activeClass = filter == activeFilter ? " active" : ""
            let url = filter == "all" ? "/runs" : "/runs?status=" + filter
            return "<a class=\"filter-tab" + activeClass + "\" href=\"" + url + "\" hx-get=\"" + url + "\" hx-target=\"#content\" hx-push-url=\"true\">" + label + "</a>"
        }.joined(separator: "\n")

        let listHTML = renderRunsList(runs)
        let statusQuery = statusFilter.map { "&status=" + $0 } ?? ""

        return "<div class=\"runs-page\">"
            + "<div class=\"runs-header\">"
            + "<h2>Workflow Runs</h2>"
            + "<div class=\"filter-tabs\">"
            + filterHTML
            + "</div></div>"
            + "<div class=\"runs-list\" id=\"runs-list\""
            + " hx-get=\"/runs?partial=true" + statusQuery + "\""
            + " hx-trigger=\"sse:run:created, sse:run:updated\""
            + " hx-swap=\"innerHTML\">"
            + listHTML
            + "</div></div>"
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
