import ArgumentParser
import Testing
@testable import CLI

@Suite("StartCommand - Input Parsing")
struct InputParsingTests {
    @Test("parses valid key=value pair")
    func validPair() throws {
        let result = try StartCommand.parseInputPairs(["name=Alice"])
        #expect(result == ["name": "Alice"])
    }

    @Test("parses multiple pairs")
    func multiplePairs() throws {
        let result = try StartCommand.parseInputPairs(["a=1", "b=2"])
        #expect(result == ["a": "1", "b": "2"])
    }

    @Test("value containing equals sign")
    func valueWithEquals() throws {
        let result = try StartCommand.parseInputPairs(["url=http://a=b"])
        #expect(result == ["url": "http://a=b"])
    }

    @Test("empty value is allowed")
    func emptyValue() throws {
        let result = try StartCommand.parseInputPairs(["key="])
        #expect(result == ["key": ""])
    }

    @Test("missing equals sign throws")
    func missingEquals() {
        #expect(throws: ExitCode.self) {
            _ = try StartCommand.parseInputPairs(["noequalssign"])
        }
    }

    @Test("empty key throws")
    func emptyKey() {
        #expect(throws: ExitCode.self) {
            _ = try StartCommand.parseInputPairs(["=value"])
        }
    }

    @Test("empty array returns empty dictionary")
    func emptyArray() throws {
        let result = try StartCommand.parseInputPairs([])
        #expect(result.isEmpty)
    }
}
