import Foundation
import Testing
import Models
@testable import Server

@Suite("StreamingEventSource")
struct StreamingEventSourceTests {

    @Test("Maps runStarted to runCreated")
    func mapsRunStarted() async throws {
        let run = Run(
            id: "r1", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .running, workspacePath: "/tmp/ws"
        )
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.runStarted(run))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "run:created")
    }

    @Test("Maps runCompleted to runUpdated")
    func mapsRunCompleted() async throws {
        let run = Run(
            id: "r1", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .completed, workspacePath: "/tmp/ws"
        )
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.runCompleted(run))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "run:updated")
    }

    @Test("Maps runFailed to runUpdated")
    func mapsRunFailed() async throws {
        let run = Run(
            id: "r1", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .failed, workspacePath: "/tmp/ws"
        )
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.runFailed(run, error: "something went wrong"))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "run:updated")
    }

    @Test("Maps nodeStarted to nodeUpdated with running status")
    func mapsNodeStarted() async throws {
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.nodeStarted(nodeID: "build", runID: "r1", agent: "shell"))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "node:updated")
    }

    @Test("Maps nodeCompleted to nodeUpdated")
    func mapsNodeCompleted() async throws {
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.nodeCompleted(nodeID: "build", runID: "r1", output: "success"))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "node:updated")
    }

    @Test("Maps nodeFailed to nodeUpdated")
    func mapsNodeFailed() async throws {
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.nodeFailed(nodeID: "build", runID: "r1", error: "compile error"))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "node:updated")
    }

    @Test("Maps nodeSkipped to nodeUpdated")
    func mapsNodeSkipped() async throws {
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.nodeSkipped(nodeID: "deploy", runID: "r1"))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.count == 1)
        #expect(monitorEvents.first?.eventName == "node:updated")
    }

    @Test("Drops nodeOutput events")
    func dropsNodeOutput() async throws {
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.nodeOutput(nodeID: "build", runID: "r1", chunk: "hello", stream: .stdout))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var monitorEvents: [MonitorEvent] = []
        for await event in source.events() {
            monitorEvents.append(event)
        }

        #expect(monitorEvents.isEmpty)
    }

    @Test("Maps full workflow lifecycle")
    func fullLifecycle() async throws {
        let run = Run(
            id: "r1", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .running, workspacePath: "/tmp/ws"
        )
        let completedRun = Run(
            id: "r1", workflowName: "test", workflowFile: "/tmp/test.yml",
            status: .completed, workspacePath: "/tmp/ws"
        )

        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            continuation.yield(.runStarted(run))
            continuation.yield(.nodeStarted(nodeID: "build", runID: "r1", agent: "shell"))
            continuation.yield(.nodeOutput(nodeID: "build", runID: "r1", chunk: "compiling...", stream: .stdout))
            continuation.yield(.nodeCompleted(nodeID: "build", runID: "r1", output: "done"))
            continuation.yield(.runCompleted(completedRun))
            continuation.finish()
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)
        var eventNames: [String] = []
        for await event in source.events() {
            eventNames.append(event.eventName)
        }

        // nodeOutput is dropped, so 4 events: runCreated, nodeUpdated(started), nodeUpdated(completed), runUpdated
        #expect(eventNames == ["run:created", "node:updated", "node:updated", "run:updated"])
    }

    @Test("Shutdown stops event iteration")
    func shutdownStops() async throws {
        let workflowEvents = AsyncThrowingStream<WorkflowEvent, any Error> { continuation in
            // Don't finish - simulate a long-running stream
            continuation.yield(.nodeStarted(nodeID: "build", runID: "r1", agent: "shell"))
            // Stream will be stopped by shutdown
        }

        let source = StreamingEventSource(workflowEvents: workflowEvents)

        // Shutdown immediately
        await source.shutdown()

        var count = 0
        for await _ in source.events() {
            count += 1
        }

        // May get 0 or 1 events depending on timing
        #expect(count <= 1)
    }
}
