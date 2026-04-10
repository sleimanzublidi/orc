import Foundation
import Models

/// Output formatting utilities for the CLI.
enum Format {

    // MARK: - Error Output

    /// Writes a message to stderr.
    static func printError(_ message: String) {
        var stderr = StandardError()
        print(message, to: &stderr)
    }

    // MARK: - Date Formatting

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Formats a Date as an ISO 8601 string.
    static func date(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    // MARK: - Duration Formatting

    /// Formats a duration in seconds as a human-readable string.
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else if seconds < 3600 {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m \(secs)s"
        } else {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }

    // MARK: - Status Formatting

    /// Returns a text indicator for a run status.
    static func statusIndicator(_ status: RunStatus) -> String {
        switch status {
        case .pending: return "[pending]"
        case .running: return "[running]"
        case .awaitingInput: return "[awaiting_input]"
        case .completed: return "[completed]"
        case .failed: return "[failed]"
        case .cancelled: return "[cancelled]"
        }
    }

    /// Returns a text indicator for a node status.
    static func nodeStatusIndicator(_ status: NodeStatus) -> String {
        switch status {
        case .pending: return "[pending]"
        case .running: return "[running]"
        case .awaitingInput: return "[awaiting_input]"
        case .completed: return "[completed]"
        case .failed: return "[failed]"
        case .skipped: return "[skipped]"
        case .cancelled: return "[cancelled]"
        }
    }

    // MARK: - Table Formatting

    /// Prints a table with aligned columns.
    static func printTable(headers: [String], rows: [[String]]) {
        guard !headers.isEmpty else { return }

        var widths = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        let headerLine = headers.enumerated().map { i, h in
            padRight(h, to: widths[i])
        }.joined(separator: "  ")
        print(headerLine)

        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
        print(separator)

        for row in rows {
            let line = row.enumerated().map { i, cell in
                padRight(cell, to: i < widths.count ? widths[i] : cell.count)
            }.joined(separator: "  ")
            print(line)
        }
    }

    // MARK: - File Size Formatting

    /// Formats a file size in bytes as a human-readable string.
    static func fileSize(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }

    // MARK: - Private

    private static func padRight(_ string: String, to width: Int) -> String {
        if string.count >= width {
            return string
        }
        return string + String(repeating: " ", count: width - string.count)
    }
}

/// A TextOutputStream that writes to stderr.
private struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
