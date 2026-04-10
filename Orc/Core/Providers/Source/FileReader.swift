import Foundation

// MARK: - FileReader

/// Shared utility for reading file contents, used by provider implementations
/// to read stdout/stderr files produced by subprocess execution.
public enum FileReader {
    /// Reads the contents of a file as a trimmed UTF-8 string.
    /// Returns an empty string if the file does not exist or is unreadable.
    public static func readContents(at path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
