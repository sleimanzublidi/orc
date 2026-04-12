import Hummingbird
import Engine
import Models

func addStatsRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("stats") { _, _ -> Response in
        let stats = try await engine.getStats()
        return try jsonResponse(stats)
    }
}
