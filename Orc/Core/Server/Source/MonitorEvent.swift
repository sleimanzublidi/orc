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
