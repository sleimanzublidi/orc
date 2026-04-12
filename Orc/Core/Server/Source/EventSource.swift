import Engine
import Models
import Foundation
import Logging

protocol EventProviding: Sendable {
    func events() -> AsyncStream<MonitorEvent>
    func shutdown() async
}

actor EventStateStore {
    var lastRunStates: [String: RunStatus] = [:]
    var lastNodeStates: [String: NodeStatus] = [:]
    var knownRunIDs: Set<String> = []
    var isShutdown = false

    func setShutdown() { isShutdown = true }
    func checkShutdown() -> Bool { isShutdown }

    func initRun(_ run: Run) {
        lastRunStates[run.id] = run.status
        knownRunIDs.insert(run.id)
    }

    func initNode(_ node: NodeExecution) {
        lastNodeStates[node.id] = node.status
    }

    func snapshot() -> (runStates: [String: RunStatus], knownIDs: Set<String>, nodeStates: [String: NodeStatus]) {
        (lastRunStates, knownRunIDs, lastNodeStates)
    }

    func updateRun(_ run: Run) {
        knownRunIDs.insert(run.id)
        lastRunStates[run.id] = run.status
    }

    func updateNode(_ node: NodeExecution) {
        lastNodeStates[node.id] = node.status
    }
}

final class PollingEventSource: EventProviding, Sendable {
    private let engine: any OrcEngineProviding
    private let pollInterval: Duration
    private let logger: Logger
    private let runIDFilter: String?
    private let store = EventStateStore()

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
            let task = Task { [self] in
                await self.initializeSnapshot()

                var heartbeatCounter = 0
                let heartbeatInterval = 15

                while !Task.isCancelled {
                    if await store.checkShutdown() { break }

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

    func shutdown() async {
        await store.setShutdown()
    }

    private func initializeSnapshot() async {
        do {
            let runs = try await engine.listRuns(status: nil)
            let filtered = filterRuns(runs)
            for run in filtered {
                await store.initRun(run)
            }

            for run in filtered where run.status == .running || run.status == .awaitingInput {
                let nodes = try await engine.getNodeExecutions(runID: run.id, nodeID: nil)
                for node in nodes {
                    await store.initNode(node)
                }
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

            let snap = await store.snapshot()

            for run in filtered {
                if !snap.knownIDs.contains(run.id) {
                    events.append(.runCreated(run))
                    await store.updateRun(run)
                } else if snap.runStates[run.id] != run.status {
                    events.append(.runUpdated(run))
                    await store.updateRun(run)
                }
            }

            let activeRuns = filtered.filter { $0.status == .running || $0.status == .awaitingInput }
            for run in activeRuns {
                let nodes = try await engine.getNodeExecutions(runID: run.id, nodeID: nil)

                for node in nodes {
                    if snap.nodeStates[node.id] != node.status {
                        events.append(.nodeUpdated(node))
                        await store.updateNode(node)
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
