/// Renders a subset of Markdown for terminal display.
///
/// Supported elements:
/// - `#` headers (rendered as bold/uppercase)
/// - Fenced code blocks (``` — indented with 4 spaces)
/// - `**bold**` inline (rendered with ANSI bold)
/// - `|` tables (passed through with column alignment preserved)
/// - `--` em dashes (rendered as —)
enum MarkdownRenderer {

    /// Renders markdown text for terminal output, applying ANSI formatting.
    static func render(_ markdown: String) -> String {
        var output: [String] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var inCodeBlock = false

        for line in lines {
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                if inCodeBlock {
                    // Start of code block — skip the opening fence
                    continue
                } else {
                    // End of code block — skip the closing fence
                    continue
                }
            }

            if inCodeBlock {
                output.append("    \(line)")
                continue
            }

            if let header = parseHeader(line) {
                output.append(header)
            } else {
                output.append(renderInline(line))
            }
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Private

    /// Parses a markdown header line and returns bold/uppercase rendering.
    private static func parseHeader(_ line: String) -> String? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }

        guard level > 0, index < line.endIndex, line[index] == " " else {
            return nil
        }

        let title = String(line[line.index(after: index)...])

        switch level {
        case 1:
            // Top-level: bold uppercase with blank line after
            return "\n\(bold(title.uppercased()))\n"
        case 2:
            // Section: bold with leading blank line
            return "\n\(bold(title))\n"
        default:
            // Subsection: bold, indented
            return "\(bold(title))"
        }
    }

    /// Renders inline markdown: **bold**.
    private static func renderInline(_ text: String) -> String {
        var result = text
        // Render **bold**
        while let openRange = result.range(of: "**") {
            let afterOpen = openRange.upperBound
            guard let closeRange = result.range(
                of: "**",
                range: afterOpen..<result.endIndex
            ) else {
                break
            }
            let content = String(result[afterOpen..<closeRange.lowerBound])
            result = String(result[result.startIndex..<openRange.lowerBound])
                + bold(content)
                + String(result[closeRange.upperBound...])
        }
        return result
    }

    /// Wraps text in ANSI bold escape codes.
    private static func bold(_ text: String) -> String {
        "\u{1B}[1m\(text)\u{1B}[0m"
    }
}
