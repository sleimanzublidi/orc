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
    func htmlEscape() {
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
