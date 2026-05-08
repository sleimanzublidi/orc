import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("WorkflowPackager")
struct WorkflowPackagerTests {

    // MARK: - Fixture setup

    /// Creates a temporary `.orc/` directory and returns its absolute path.
    /// Caller is responsible for removing the parent dir; we return the parent so
    /// they can clean up.
    private func makeFixtureProject(
        files: [String: String]
    ) throws -> (basePath: String, parent: String) {
        let parent = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("orc-pack-tests-\(UUID().uuidString)")
        let basePath = parent.appendingPathComponent(".orc")
        try FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        for (relative, contents) in files {
            let absolute = basePath.appendingPathComponent(relative)
            let parentDir = absolute.deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try contents.write(toFile: absolute, atomically: true, encoding: .utf8)
        }
        return (basePath, parent)
    }

    /// Mock engine that returns a parsed workflow built by the supplied closure.
    private func mockEngine(
        validate: @escaping (String) -> (Workflow, ValidationResult)
    ) -> MockEngine {
        let mock = MockEngine()
        mock.validateHandler = { path in
            validate(path)
        }
        return mock
    }

    // MARK: - Tests

    @Test("packs a single workflow with no references")
    func packsSingleWorkflow() async throws {
        let (basePath, parent) = try makeFixtureProject(files: [
            "workflows/hello.yaml": "name: hello\n"
        ])
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let mock = mockEngine { path in
            let workflow = Workflow(name: "hello", description: "say hi", nodes: [
                Node(id: "shell", agent: .literal("shell"), command: "echo hi")
            ])
            return (workflow, ValidationResult(errors: [], warnings: []))
        }
        let outputPath = parent.appendingPathComponent("hello.orc-workflow")

        let result = try await WorkflowPackager.pack(
            workflowArgument: "hello",
            basePath: basePath,
            outputPath: outputPath,
            version: "1.0.0",
            description: nil,
            author: nil,
            extraFiles: [],
            engine: mock
        )

        #expect(result.manifest.name == "hello")
        #expect(result.manifest.entrypoint == "workflows/hello.yaml")
        #expect(result.manifest.files == ["workflows/hello.yaml"])
        #expect(FileManager.default.fileExists(atPath: outputPath))
    }

    @Test("discovers prompt files referenced via {{orc_root}} prefix")
    func discoversPromptFiles() async throws {
        let (basePath, parent) = try makeFixtureProject(files: [
            "workflows/main.yaml": "name: main\n",
            "prompts/intro.md": "intro prompt"
        ])
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let mock = mockEngine { _ in
            let workflow = Workflow(name: "main", nodes: [
                Node(
                    id: "talk",
                    agent: .literal("claude-code"),
                    promptFile: "{{orc_root}}/prompts/intro.md"
                )
            ])
            return (workflow, ValidationResult(errors: [], warnings: []))
        }
        let outputPath = parent.appendingPathComponent("main.orc-workflow")

        let result = try await WorkflowPackager.pack(
            workflowArgument: "main",
            basePath: basePath,
            outputPath: outputPath,
            version: "0.1.0",
            description: nil,
            author: nil,
            extraFiles: [],
            engine: mock
        )

        #expect(result.manifest.files.contains("workflows/main.yaml"))
        #expect(result.manifest.files.contains("prompts/intro.md"))
    }

    @Test("recursively discovers sub-workflow references via .orc/ prefix")
    func discoversSubWorkflows() async throws {
        let (basePath, parent) = try makeFixtureProject(files: [
            "workflows/parent.yaml": "name: parent\n",
            "workflows/child.yaml": "name: child\n"
        ])
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let mock = MockEngine()
        mock.validateHandler = { path in
            if path.hasSuffix("/parent.yaml") {
                let parent = Workflow(name: "parent", nodes: [
                    Node(id: "child", workflow: ".orc/workflows/child.yaml")
                ])
                return (parent, ValidationResult(errors: [], warnings: []))
            }
            let child = Workflow(name: "child", nodes: [
                Node(id: "leaf", agent: .literal("shell"), command: "echo")
            ])
            return (child, ValidationResult(errors: [], warnings: []))
        }
        let outputPath = parent.appendingPathComponent("parent.orc-workflow")

        let result = try await WorkflowPackager.pack(
            workflowArgument: "parent",
            basePath: basePath,
            outputPath: outputPath,
            version: "1.0.0",
            description: nil,
            author: nil,
            extraFiles: [],
            engine: mock
        )

        #expect(result.manifest.files.contains("workflows/parent.yaml"))
        #expect(result.manifest.files.contains("workflows/child.yaml"))
    }

    @Test("rejects unsupported reference paths")
    func rejectsUnsupportedReference() async throws {
        let (basePath, parent) = try makeFixtureProject(files: [
            "workflows/main.yaml": "name: main\n"
        ])
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let mock = mockEngine { _ in
            let workflow = Workflow(name: "main", nodes: [
                Node(id: "weird", agent: .literal("claude-code"),
                     promptFile: "/absolute/path/nope.md")
            ])
            return (workflow, ValidationResult(errors: [], warnings: []))
        }
        let outputPath = parent.appendingPathComponent("main.orc-workflow")

        await #expect {
            _ = try await WorkflowPackager.pack(
                workflowArgument: "main",
                basePath: basePath,
                outputPath: outputPath,
                version: "1.0.0",
                description: nil,
                author: nil,
                extraFiles: [],
                engine: mock
            )
        } throws: { error in
            if case WorkflowPackager.Error.unsupportedReferencePath = error { return true }
            return false
        }
    }

    @Test("propagates validation errors from the engine")
    func propagatesValidationErrors() async throws {
        let (basePath, parent) = try makeFixtureProject(files: [
            "workflows/broken.yaml": "name: broken\n"
        ])
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let mock = mockEngine { _ in
            let workflow = Workflow(name: "broken")
            let validation = ValidationResult(
                errors: [ValidationError(message: "cyclic dep", nodeID: "x")],
                warnings: []
            )
            return (workflow, validation)
        }
        let outputPath = parent.appendingPathComponent("broken.orc-workflow")

        await #expect {
            _ = try await WorkflowPackager.pack(
                workflowArgument: "broken",
                basePath: basePath,
                outputPath: outputPath,
                version: "1.0.0",
                description: nil,
                author: nil,
                extraFiles: [],
                engine: mock
            )
        } throws: { error in
            if case WorkflowPackager.Error.validationFailed = error { return true }
            return false
        }
    }

    @Test("includes extra files supplied via --include")
    func includesExtraFiles() async throws {
        let (basePath, parent) = try makeFixtureProject(files: [
            "workflows/main.yaml": "name: main\n",
            "data/seed.json": "{\"v\":1}"
        ])
        defer { try? FileManager.default.removeItem(atPath: parent) }

        let mock = mockEngine { _ in
            let workflow = Workflow(name: "main", nodes: [])
            return (workflow, ValidationResult(errors: [], warnings: []))
        }
        let outputPath = parent.appendingPathComponent("main.orc-workflow")

        let result = try await WorkflowPackager.pack(
            workflowArgument: "main",
            basePath: basePath,
            outputPath: outputPath,
            version: "1.0.0",
            description: nil,
            author: nil,
            extraFiles: ["data/seed.json"],
            engine: mock
        )

        #expect(result.manifest.files.contains("data/seed.json"))
    }
}
