import Models
import Testing

@testable import Providers

@Suite("ProviderRegistry")
struct ProviderRegistryTests {

    @Test("Looks up registered provider by name")
    func lookupByName() throws {
        let shell = ShellProvider(
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )
        let claude = ClaudeCodeProvider(
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )

        let registry = ProviderRegistry(providers: [shell, claude])

        let found = try registry.provider(named: "shell")
        #expect(found.name == "shell")

        let foundClaude = try registry.provider(named: "claude-code")
        #expect(foundClaude.name == "claude-code")
    }

    @Test("Throws providerNotFound for unknown name")
    func unknownName() {
        let registry = ProviderRegistry(providers: [])

        #expect(throws: ProviderError.self) {
            _ = try registry.provider(named: "nonexistent")
        }
    }

    @Test("Throws providerNotFound with correct name")
    func providerNotFoundName() {
        let registry = ProviderRegistry(providers: [])

        do {
            _ = try registry.provider(named: "ghost-agent")
            Issue.record("Expected ProviderError.providerNotFound")
        } catch let error as ProviderError {
            #expect(error == .providerNotFound(name: "ghost-agent"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Last registration wins for duplicate names")
    func duplicateNames() throws {
        let agent1 = CLIAgentProvider(
            name: "duplicate",
            commandTemplate: "first {{prompt}}",
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )
        let agent2 = CLIAgentProvider(
            name: "duplicate",
            commandTemplate: "second {{prompt}}",
            processRunner: FakeProcessRunner(exitCode: 0),
            tmuxProvider: FakeTmuxProvider()
        )

        let registry = ProviderRegistry(providers: [agent1, agent2])
        let found = try registry.provider(named: "duplicate")
        #expect(found.name == "duplicate")
    }

    @Test("Empty registry has no providers")
    func emptyRegistry() {
        let registry = ProviderRegistry()

        #expect(throws: ProviderError.self) {
            _ = try registry.provider(named: "anything")
        }
    }
}
