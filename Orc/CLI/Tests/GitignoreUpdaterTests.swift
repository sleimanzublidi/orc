import Foundation
import Testing

@testable import CLI

@Suite("GitignoreUpdater")
struct GitignoreUpdaterTests {
    @Test("creates gitignore with Orc rules when missing")
    func createsGitignore() throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let changed = try GitignoreUpdater.ensureOrcRules(in: project.path)
        let content = try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)

        #expect(changed)
        #expect(content == expectedOrcBlock)
    }

    @Test("normalizes existing Orc rules with self-improve exceptions")
    func normalizesExistingRules() throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let gitignore = project.appendingPathComponent(".gitignore")
        try """
        .build/

        # Orc
        .orc/*
        !.orc/workflows/
        !.orc/self-improve/ideas-backlog.md
        """.write(to: gitignore, atomically: true, encoding: .utf8)

        let changed = try GitignoreUpdater.ensureOrcRules(in: project.path)
        let content = try String(contentsOf: gitignore, encoding: .utf8)

        #expect(changed)
        #expect(content == ".build/\n\n" + expectedOrcBlock)
    }

    @Test("is idempotent when rules are already normalized")
    func idempotent() throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let gitignore = project.appendingPathComponent(".gitignore")
        let existingContent = "build/\n\n" + expectedOrcBlock + "local-only.txt\n"
        try existingContent.write(to: gitignore, atomically: true, encoding: .utf8)

        let changed = try GitignoreUpdater.ensureOrcRules(in: project.path)
        let content = try String(contentsOf: gitignore, encoding: .utf8)

        #expect(!changed)
        #expect(content == existingContent)
    }

    private func makeTempProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orc-gitignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private let expectedOrcBlock = """
# Orc
.orc/*
!.orc/evaluators/
!.orc/prompts/
!.orc/self-improve/
.orc/self-improve/*
!.orc/self-improve/ideas-backlog.md
!.orc/self-improve/known-issues.md
!.orc/workflows/

"""
