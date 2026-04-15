import Foundation
import Testing
@testable import CLI

@Suite("RunFilterParsing - Duration and Date Parsing")
struct DurationParsingTests {

    // MARK: - Duration Format

    @Test("parses valid day durations")
    func validDays() {
        let now = Date()
        let result = RunFilterParsing.parseDateOrDuration("30d")
        let expected = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        #expect(result != nil)
        #expect(abs(result!.timeIntervalSince(expected)) < 1.0)
    }

    @Test("returns nil for zero days")
    func zeroDays() {
        #expect(RunFilterParsing.parseDateOrDuration("0d") == nil)
    }

    @Test("returns nil for negative days")
    func negativeDays() {
        #expect(RunFilterParsing.parseDateOrDuration("-5d") == nil)
    }

    @Test("returns nil for missing d suffix")
    func missingSuffix() {
        #expect(RunFilterParsing.parseDateOrDuration("30") == nil)
    }

    @Test("returns nil for non-numeric prefix")
    func nonNumeric() {
        #expect(RunFilterParsing.parseDateOrDuration("abcd") == nil)
    }

    @Test("returns nil for just d")
    func justD() {
        #expect(RunFilterParsing.parseDateOrDuration("d") == nil)
    }

    @Test("returns nil for empty string")
    func emptyString() {
        #expect(RunFilterParsing.parseDateOrDuration("") == nil)
    }

    // MARK: - ISO Date Format

    @Test("parses valid ISO date")
    func validISODate() {
        let result = RunFilterParsing.parseDateOrDuration("2026-04-15")
        #expect(result != nil)
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: result!
        )
        #expect(components.year == 2026)
        #expect(components.month == 4)
        #expect(components.day == 15)
    }

    @Test("returns nil for invalid date string")
    func invalidDate() {
        #expect(RunFilterParsing.parseDateOrDuration("not-a-date") == nil)
    }

    // MARK: - Positional Classification

    @Test("classifies 'all'")
    func classifiesAll() {
        guard case .all = RunFilterParsing.classifyPositional("all") else {
            Issue.record("Expected .all")
            return
        }
    }

    @Test("classifies valid status")
    func classifiesStatus() {
        guard case .status(let s) = RunFilterParsing.classifyPositional("completed") else {
            Issue.record("Expected .status")
            return
        }
        #expect(s == .completed)
    }

    @Test("classifies date with < prefix")
    func classifiesDate() {
        guard case .olderThan = RunFilterParsing.classifyPositional("<2026-04-15") else {
            Issue.record("Expected .olderThan")
            return
        }
    }

    @Test("returns nil for invalid date with < prefix")
    func invalidDatePrefix() {
        #expect(RunFilterParsing.classifyPositional("<not-a-date") == nil)
    }

    @Test("classifies unknown string as runID")
    func classifiesRunID() {
        guard case .runID(let id) = RunFilterParsing.classifyPositional("abc12345") else {
            Issue.record("Expected .runID")
            return
        }
        #expect(id == "abc12345")
    }
}
