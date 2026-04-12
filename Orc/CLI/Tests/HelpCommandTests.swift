import Foundation
import Testing
@testable import CLI

@Suite("HelpCommand")
struct HelpCommandTests {

    @Test("loadManifest returns all 8 topics")
    func loadManifest() throws {
        let manifest = try HelpCommand.loadManifest()
        #expect(manifest.topics.count == 8)
        #expect(manifest.version == "1.0.0")
    }

    @Test("loadManifest topic IDs match expected set")
    func topicIDs() throws {
        let manifest = try HelpCommand.loadManifest()
        let ids = Set(manifest.topics.map(\.id))
        let expected: Set<String> = [
            "workflows", "templates", "loops", "providers",
            "custom-agents", "interactive-nodes", "nested-workflows", "run-management",
        ]
        #expect(ids == expected)
    }

    @Test("each topic has non-empty title and description")
    func topicMetadata() throws {
        let manifest = try HelpCommand.loadManifest()
        for topic in manifest.topics {
            #expect(!topic.title.isEmpty, "Topic \(topic.id) has empty title")
            #expect(!topic.description.isEmpty, "Topic \(topic.id) has empty description")
        }
    }

    @Test("loadTopicContent returns content for each topic")
    func loadAllTopics() throws {
        let manifest = try HelpCommand.loadManifest()
        for topic in manifest.topics {
            let content = HelpCommand.loadTopicContent(topic.file)
            #expect(content != nil, "Content missing for \(topic.id)")
            #expect(content?.isEmpty == false, "Content empty for \(topic.id)")
        }
    }

    @Test("loadTopicContent returns nil for unknown file")
    func unknownTopic() {
        let content = HelpCommand.loadTopicContent("nonexistent.md")
        #expect(content == nil)
    }
}
