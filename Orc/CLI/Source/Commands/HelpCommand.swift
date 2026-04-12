import ArgumentParser
import Foundation

struct HelpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "help",
        abstract: "Display help for Orc topics"
    )

    @Argument(help: "Topic to display (e.g. workflows, templates, loops)")
    var topic: String?

    func run() async throws {
        let manifest = try Self.loadManifest()

        guard let topic else {
            printTopicList(manifest)
            return
        }

        guard let entry = manifest.topics.first(where: { $0.id == topic }) else {
            Format.printError("Unknown topic: \(topic)")
            print("")
            print("Available topics:")
            for t in manifest.topics {
                print("  \(t.id)")
            }
            throw ExitCode.failure
        }

        guard let content = Self.loadTopicContent(entry.file) else {
            Format.printError("Help content not found for '\(entry.id)'.")
            throw ExitCode.failure
        }

        print(MarkdownRenderer.render(content))
    }

    // MARK: - Topic Listing

    private func printTopicList(_ manifest: HelpManifest) {
        print("Available help topics:\n")
        let rows = manifest.topics.map { [$0.id, $0.description] }
        Format.printTable(headers: ["Topic", "Description"], rows: rows)
        print("\nRun 'orc help <topic>' to read a topic.")
    }

    // MARK: - Embedded Content Loading

    /// Help manifest decoded from the embedded help.json.
    struct HelpManifest: Decodable, Sendable {
        let version: String
        let topics: [Topic]

        struct Topic: Decodable, Sendable {
            let id: String
            let title: String
            let description: String
            let file: String
        }
    }

    static func loadManifest() throws -> HelpManifest {
        guard let json = EmbeddedDefaults.files
            .first(where: { $0.path == "help/help.json" })?
            .content
        else {
            Format.printError("Help manifest not found.")
            throw ExitCode.failure
        }

        guard let data = json.data(using: .utf8) else {
            Format.printError("Help manifest is not valid UTF-8.")
            throw ExitCode.failure
        }

        return try JSONDecoder().decode(HelpManifest.self, from: data)
    }

    static func loadTopicContent(_ filename: String) -> String? {
        EmbeddedDefaults.files
            .first(where: { $0.path == "help/\(filename)" })?
            .content
    }
}
