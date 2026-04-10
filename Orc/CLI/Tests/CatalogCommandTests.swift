import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("CatalogCommand")
struct CatalogCommandTests {

    @Test("displays empty catalog with (none) for both sections")
    func emptyCatalog() async throws {
        let mock = MockEngine()
        mock.catalogHandler = {
            TestFixtures.makeCatalog()
        }

        let cmd = try CatalogCommand.parseAsRoot([]) as! CatalogCommand
        try await cmd.execute(engine: mock)
    }

    @Test("displays workflows with names and descriptions")
    func withWorkflows() async throws {
        let mock = MockEngine()
        mock.catalogHandler = {
            TestFixtures.makeCatalog(workflows: [
                TestFixtures.makeCatalogEntry(name: "hello-world", description: "A simple greeting workflow", fileName: "hello-world.yaml"),
                TestFixtures.makeCatalogEntry(name: "deploy", description: "Deploy to production", fileName: "deploy.yml"),
            ])
        }

        let cmd = try CatalogCommand.parseAsRoot([]) as! CatalogCommand
        try await cmd.execute(engine: mock)
    }

    @Test("displays evaluators with names and descriptions")
    func withEvaluators() async throws {
        let mock = MockEngine()
        mock.catalogHandler = {
            TestFixtures.makeCatalog(evaluators: [
                TestFixtures.makeCatalogEntry(name: "quality-check", description: "AI-based quality evaluator", fileName: "quality-check.yml"),
            ])
        }

        let cmd = try CatalogCommand.parseAsRoot([]) as! CatalogCommand
        try await cmd.execute(engine: mock)
    }

    @Test("displays (parse error) for entries with nil description")
    func parseError() async throws {
        let mock = MockEngine()
        mock.catalogHandler = {
            TestFixtures.makeCatalog(workflows: [
                TestFixtures.makeCatalogEntry(name: "broken.yml", description: nil, fileName: "broken.yml"),
            ])
        }

        let cmd = try CatalogCommand.parseAsRoot([]) as! CatalogCommand
        try await cmd.execute(engine: mock)
    }

    @Test("displays both workflows and evaluators together")
    func fullCatalog() async throws {
        let mock = MockEngine()
        mock.catalogHandler = {
            TestFixtures.makeCatalog(
                workflows: [
                    TestFixtures.makeCatalogEntry(name: "build", description: "Build the project", fileName: "build.yaml"),
                ],
                evaluators: [
                    TestFixtures.makeCatalogEntry(name: "lint-check", description: "Run linter", fileName: "lint-check.yml"),
                ]
            )
        }

        let cmd = try CatalogCommand.parseAsRoot([]) as! CatalogCommand
        try await cmd.execute(engine: mock)
    }
}
