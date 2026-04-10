import Foundation
import Testing
@testable import CLI

@Suite("PurgeCommand - Duration Parsing")
struct DurationParsingTests {
    @Test("parses valid day durations")
    func validDays() {
        let now = Date()
        let result = parseDuration("30d")
        let expected = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        #expect(result != nil)
        #expect(abs(result!.timeIntervalSince(expected)) < 1.0)
    }

    @Test("returns nil for zero days")
    func zeroDays() {
        #expect(parseDuration("0d") == nil)
    }

    @Test("returns nil for negative days")
    func negativeDays() {
        #expect(parseDuration("-5d") == nil)
    }

    @Test("returns nil for missing d suffix")
    func missingSuffix() {
        #expect(parseDuration("30") == nil)
    }

    @Test("returns nil for non-numeric prefix")
    func nonNumeric() {
        #expect(parseDuration("abcd") == nil)
    }

    @Test("returns nil for just d")
    func justD() {
        #expect(parseDuration("d") == nil)
    }

    @Test("returns nil for empty string")
    func emptyString() {
        #expect(parseDuration("") == nil)
    }
}
