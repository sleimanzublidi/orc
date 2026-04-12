import Hummingbird
import Engine
import Models

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
