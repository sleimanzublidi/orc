import Foundation
import Testing

@testable import CLI

@Suite("WorkflowPackageManifestCoder")
struct WorkflowPackageManifestCoderTests {

    @Test("encodes a minimal manifest with required fields")
    func encodesMinimalManifest() throws {
        let manifest = WorkflowPackageManifest(
            name: "deploy",
            version: "1.0.0",
            description: nil,
            author: nil,
            minOrcVersion: nil,
            entrypoint: "workflows/deploy.yaml",
            files: ["workflows/deploy.yaml", "prompts/deploy.md"]
        )
        let yaml = WorkflowPackageManifestCoder.encode(manifest)

        #expect(yaml.contains("name: deploy"))
        #expect(yaml.contains("version: 1.0.0"))
        #expect(yaml.contains("entrypoint: workflows/deploy.yaml"))
        #expect(yaml.contains("- workflows/deploy.yaml"))
        #expect(yaml.contains("- prompts/deploy.md"))
        #expect(!yaml.contains("description:"))
        #expect(!yaml.contains("author:"))
    }

    @Test("encodes optional fields when present")
    func encodesOptionalFields() throws {
        let manifest = WorkflowPackageManifest(
            name: "deploy",
            version: "1.0.0",
            description: "A deploy workflow",
            author: "Alice",
            minOrcVersion: "0.9.0",
            entrypoint: "workflows/deploy.yaml",
            files: ["workflows/deploy.yaml"]
        )
        let yaml = WorkflowPackageManifestCoder.encode(manifest)
        #expect(yaml.contains("description: A deploy workflow"))
        #expect(yaml.contains("author: Alice"))
        #expect(yaml.contains("min_orc_version: 0.9.0"))
    }

    @Test("round-trips encode -> decode")
    func roundTrip() throws {
        let original = WorkflowPackageManifest(
            name: "deploy",
            version: "1.2.3",
            description: "uses: colon and # hash",
            author: "Author Name",
            minOrcVersion: "1.0.0",
            entrypoint: "workflows/deploy.yaml",
            files: ["workflows/deploy.yaml", "prompts/a.md", "prompts/b.md"]
        )
        let yaml = WorkflowPackageManifestCoder.encode(original)
        let decoded = try WorkflowPackageManifestCoder.decode(yaml)
        #expect(decoded == original)
    }

    @Test("rejects manifest missing required field")
    func rejectsMissingField() throws {
        let yaml = """
        name: deploy
        entrypoint: workflows/deploy.yaml
        files:
          - workflows/deploy.yaml
        """
        #expect(throws: WorkflowPackageManifestCoder.Error.self) {
            _ = try WorkflowPackageManifestCoder.decode(yaml)
        }
    }

    @Test("rejects manifest with wrong type for files")
    func rejectsWrongType() throws {
        let yaml = """
        name: deploy
        version: 1.0.0
        entrypoint: workflows/deploy.yaml
        files: not-a-list
        """
        #expect(throws: WorkflowPackageManifestCoder.Error.self) {
            _ = try WorkflowPackageManifestCoder.decode(yaml)
        }
    }
}
