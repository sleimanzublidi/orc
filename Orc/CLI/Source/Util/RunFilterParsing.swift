import Foundation
import Models

/// Shared parsing utilities for cleanup and purge command filters.
///
/// Both commands accept the same positional shorthand plus named options:
/// - `all` → no filter (all runs)
/// - A valid `RunStatus` raw value → filter by status
/// - `<YYYY-MM-DD` → runs updated before that date
/// - Anything else → treated as a run ID (cleanup only)
enum RunFilterParsing {

    /// Classification of a positional filter argument.
    enum PositionalKind {
        case all
        case status(RunStatus)
        case olderThan(Date)
        case runID(String)
    }

    /// Classifies a positional argument string.
    ///
    /// - Returns: The classification, or nil if the input starts with `<`
    ///   but contains an unparseable date.
    static func classifyPositional(_ input: String) -> PositionalKind? {
        if input == "all" {
            return .all
        }
        if input.hasPrefix("<") {
            let dateStr = String(input.dropFirst())
            guard let date = parseDate(dateStr) else { return nil }
            return .olderThan(date)
        }
        if let status = RunStatus(rawValue: input) {
            return .status(status)
        }
        return .runID(input)
    }

    /// Parses a duration string (e.g., `"30d"`) or ISO date (e.g., `"2026-04-15"`).
    ///
    /// Duration format produces a date that many days in the past from now.
    /// ISO date format produces start-of-day UTC for that date.
    static func parseDateOrDuration(_ input: String) -> Date? {
        if input.hasSuffix("d"),
           let days = Int(input.dropLast()),
           days > 0 {
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }
        return parseDate(input)
    }

    /// Parses an ISO 8601 date string (`YYYY-MM-DD`) into start-of-day UTC.
    static func parseDate(_ input: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: input)
    }

    /// Valid status values for error messages.
    static let validStatusValues = "pending, running, completed, failed, cancelled, awaiting_input, all"
}
