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
    group.get("runs/:id/nodes/:nodeID/logs") { request, context -> Response in
        let runID = try context.parameters.require("id")
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

        let logContents: [(stream: String, content: String, timestamp: Date)] = entries.compactMap { entry in
            guard let data = FileManager.default.contents(atPath: entry.filePath),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            return (stream: entry.stream.rawValue, content: content, timestamp: entry.timestamp)
        }

        if formatParam == "html" {
            let html = TemplateRenderer.renderLogPanel(logContents)
            return htmlResponse(html)
        }

        let response = logContents.map { LogContent(stream: $0.stream, content: $0.content, timestamp: $0.timestamp) }
        return try jsonResponse(response)
    }
}
