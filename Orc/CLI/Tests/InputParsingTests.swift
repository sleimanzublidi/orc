import ArgumentParser
import Testing
@testable import CLI

@Suite("StartCommand - Input Parsing")
struct InputParsingTests {
    @Test("parses valid key=value pair")
    func validPair() throws {
        let (result, rawParts) = try StartCommand.parseInputPairs(["name=Alice"])
        #expect(result == ["name": "Alice"])
        #expect(rawParts.isEmpty)
    }

    @Test("parses multiple pairs")
    func multiplePairs() throws {
        let (result, rawParts) = try StartCommand.parseInputPairs(["a=1", "b=2"])
        #expect(result == ["a": "1", "b": "2"])
        #expect(rawParts.isEmpty)
    }

    @Test("value containing equals sign")
    func valueWithEquals() throws {
        let (result, _) = try StartCommand.parseInputPairs(["url=http://a=b"])
        #expect(result == ["url": "http://a=b"])
    }

    @Test("empty value is allowed")
    func emptyValue() throws {
        let (result, _) = try StartCommand.parseInputPairs(["key="])
        #expect(result == ["key": ""])
    }

    @Test("missing equals sign returns item as raw part")
    func missingEquals() throws {
        let (result, rawParts) = try StartCommand.parseInputPairs(["noequalssign"])
        #expect(result.isEmpty)
        #expect(rawParts == ["noequalssign"])
    }

    @Test("empty key throws")
    func emptyKey() {
        #expect(throws: ExitCode.self) {
            _ = try StartCommand.parseInputPairs(["=value"])
        }
    }

    @Test("empty array returns empty dictionary")
    func emptyArray() throws {
        let (result, rawParts) = try StartCommand.parseInputPairs([])
        #expect(result.isEmpty)
        #expect(rawParts.isEmpty)
    }
}
