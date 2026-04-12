import Foundation

/// Loads environment variables from a `.env` file.
///
/// Supports:
/// - `KEY=VALUE` pairs (one per line)
/// - `# comments` and blank lines (skipped)
/// - Quoted values: `KEY="value"` or `KEY='value'` (quotes stripped)
/// - Inline comments after unquoted values: `KEY=value # comment`
///
/// Does not support: multi-line values, variable expansion, `export` prefix.
enum DotEnvLoader {

    /// Parses a `.env` file at the given path and returns the key-value pairs.
    /// Returns an empty dictionary if the file does not exist or cannot be read.
    static func load(from path: String) -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        return parse(contents)
    }

    /// Parses `.env` formatted content into key-value pairs.
    static func parse(_ contents: String) -> [String: String] {
        var env: [String: String] = [:]

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split on first `=`.
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = String(trimmed[trimmed.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var value = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Strip matching quotes.
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            } else {
                // Remove inline comment for unquoted values.
                if let commentIndex = value.firstIndex(of: "#") {
                    value = String(value[value.startIndex..<commentIndex])
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            env[key] = value
        }

        return env
    }
}
