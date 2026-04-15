import Hummingbird
import Engine
import Models

func addRunRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("runs") { request, _ -> Response in
        let statusParam: String? = request.uri.queryParameters["status"].map(String.init)
        let status: RunStatus? = statusParam.flatMap { RunStatus(rawValue: $0) }
        let runs = try await engine.listRuns(status: status, topLevelOnly: false)
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
