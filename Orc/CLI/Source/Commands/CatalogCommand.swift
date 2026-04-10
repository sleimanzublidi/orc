import ArgumentParser
import Engine
import Models

struct CatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "List available workflows and evaluators"
    )

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            let catalog = try await engine.catalog()

            print("Workflows:")
            if catalog.workflows.isEmpty {
                print("  (none)")
            } else {
                let rows = catalog.workflows.map { entry in
                    ["  \(entry.name)", entry.description ?? "(parse error)"]
                }
                let widths = rows.reduce(into: [0, 0]) { widths, row in
                    widths[0] = max(widths[0], row[0].count)
                    widths[1] = max(widths[1], row[1].count)
                }
                for row in rows {
                    let name = row[0].padding(toLength: widths[0], withPad: " ", startingAt: 0)
                    print("\(name)    \(row[1])")
                }
            }

            print("")
            print("Evaluators:")
            if catalog.evaluators.isEmpty {
                print("  (none)")
            } else {
                let rows = catalog.evaluators.map { entry in
                    ["  \(entry.name)", entry.description ?? "(parse error)"]
                }
                let widths = rows.reduce(into: [0, 0]) { widths, row in
                    widths[0] = max(widths[0], row[0].count)
                    widths[1] = max(widths[1], row[1].count)
                }
                for row in rows {
                    let name = row[0].padding(toLength: widths[0], withPad: " ", startingAt: 0)
                    print("\(name)    \(row[1])")
                }
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
