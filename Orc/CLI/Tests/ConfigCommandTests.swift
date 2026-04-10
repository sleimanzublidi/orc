import ArgumentParser
import Engine
import Foundation
import Models
import Testing

@testable import CLI

@Suite("ConfigCommand")
struct ConfigCommandTests {

    @Test("get mode prints value for known key")
    func getModePrintsValue() async throws {
        let mock = MockEngine()
        var receivedKey: String?
        mock.getConfigValueHandler = { key in
            receivedKey = key
            return "8"
        }

        let cmd = try ConfigCommand.parseAsRoot(
            ["concurrency.max_parallel_nodes"]
        ) as! ConfigCommand
        try await cmd.execute(engine: mock)

        #expect(receivedKey == "concurrency.max_parallel_nodes")
    }

    @Test("get mode throws for unknown key")
    func getModeThrowsForUnknownKey() async throws {
        let mock = MockEngine()
        mock.getConfigValueHandler = { _ in nil }

        let cmd = try ConfigCommand.parseAsRoot(["nonexistent.key"]) as! ConfigCommand

        await #expect(throws: ExitCode.self) {
            try await cmd.execute(engine: mock)
        }
    }

    @Test("set mode passes key and value to engine")
    func setModePassesKeyAndValue() async throws {
        let mock = MockEngine()
        var receivedKey: String?
        var receivedValue: String?
        mock.setConfigValueHandler = { key, value in
            receivedKey = key
            receivedValue = value
        }

        let cmd = try ConfigCommand.parseAsRoot(
            ["concurrency.max_parallel_nodes", "16"]
        ) as! ConfigCommand
        try await cmd.execute(engine: mock)

        #expect(receivedKey == "concurrency.max_parallel_nodes")
        #expect(receivedValue == "16")
    }

    @Test("unset mode passes key to engine")
    func unsetModePassesKey() async throws {
        let mock = MockEngine()
        var receivedKey: String?
        mock.unsetConfigValueHandler = { key in
            receivedKey = key
        }

        let cmd = try ConfigCommand.parseAsRoot(
            ["--unset", "default_shell"]
        ) as! ConfigCommand
        try await cmd.execute(engine: mock)

        #expect(receivedKey == "default_shell")
    }

    @Test("no-key mode prints all config")
    func noKeyModePrintsAllConfig() async throws {
        let mock = MockEngine()
        var loadConfigCalled = false
        mock.loadConfigHandler = {
            loadConfigCalled = true
            return OrcConfig(
                maxParallelNodes: 4,
                retentionDays: 14,
                retentionPolicy: "all",
                defaultShell: "/bin/bash"
            )
        }

        let cmd = try ConfigCommand.parseAsRoot([]) as! ConfigCommand
        try await cmd.execute(engine: mock)

        #expect(loadConfigCalled)
    }
}
