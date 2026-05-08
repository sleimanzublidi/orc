import Foundation

enum GitignoreUpdater {
    private static let header = "# Orc"
    private static let rules = [
        ".orc/*",
        "!.orc/evaluators/",
        "!.orc/prompts/",
        "!.orc/self-improve/",
        ".orc/self-improve/*",
        "!.orc/self-improve/ideas-backlog.md",
        "!.orc/self-improve/known-issues.md",
        "!.orc/workflows/",
    ]

    private static var managedLines: Set<String> {
        Set([header] + rules)
    }

    @discardableResult
    static func ensureOrcRules(in projectPath: String) throws -> Bool {
        let gitignorePath = projectPath.appendingPathComponent(".gitignore")
        let original = try readGitignore(at: gitignorePath)
        let updated = normalizedContent(from: original)

        guard updated != original else {
            return false
        }

        try updated.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        return true
    }

    private static func readGitignore(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return ""
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func normalizedContent(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") {
            lines.removeLast()
        }

        guard !hasManagedBlock(in: lines) else {
            return content
        }

        var retainedLines = lines.filter { !managedLines.contains($0) }
        while retainedLines.last?.isEmpty == true {
            retainedLines.removeLast()
        }

        if !retainedLines.isEmpty {
            retainedLines.append("")
        }
        retainedLines.append(header)
        retainedLines.append(contentsOf: rules)

        return retainedLines.joined(separator: "\n") + "\n"
    }

    private static func hasManagedBlock(in lines: [String]) -> Bool {
        var searchStart = lines.startIndex

        for expectedLine in [header] + rules {
            guard
                let matchIndex = lines[searchStart...].firstIndex(of: expectedLine)
            else {
                return false
            }
            searchStart = lines.index(after: matchIndex)
        }

        return true
    }
}
