import Hummingbird

struct HealthResponse: ResponseCodable {
    let status: String
}

func addHealthRoutes(to group: RouterGroup<BasicRequestContext>) {
    group.get("health") { _, _ -> HealthResponse in
        HealthResponse(status: "ok")
    }
}
