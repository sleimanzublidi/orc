import Hummingbird
import Engine
import Foundation

func addEventRoutes(to group: RouterGroup<BasicRequestContext>, engine: any OrcEngineProviding) {
    group.get("events") { request, _ -> Response in
        let runIDFilter: String? = request.uri.queryParameters["runID"].map(String.init)

        let source = PollingEventSource(engine: engine, runIDFilter: runIDFilter)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
            ],
            body: ResponseBody { writer in
                for await event in source.events() {
                    try Task.checkCancellation()
                    let formatted = try event.sseFormatted(encoder: encoder)
                    try await writer.write(.init(string: formatted))
                }
                try await writer.finish(nil)
            }
        )
    }
}
