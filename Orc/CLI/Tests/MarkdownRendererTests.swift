import Foundation
import Testing
@testable import CLI

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {

    private let bold = "\u{1B}[1m"
    private let reset = "\u{1B}[0m"

    // MARK: - Headers

    @Test("h1 renders as bold uppercase with surrounding blank lines")
    func h1Header() {
        let result = MarkdownRenderer.render("# Hello World")
        #expect(result.contains("\(bold)HELLO WORLD\(reset)"))
    }

    @Test("h2 renders as bold with leading blank line")
    func h2Header() {
        let result = MarkdownRenderer.render("## Section Title")
        #expect(result.contains("\(bold)Section Title\(reset)"))
    }

    @Test("h3 renders as bold")
    func h3Header() {
        let result = MarkdownRenderer.render("### Subsection")
        #expect(result.contains("\(bold)Subsection\(reset)"))
    }

    // MARK: - Code Blocks

    @Test("fenced code block lines are indented with 4 spaces")
    func codeBlockIndentation() {
        let input = "```yaml\nkey: value\nother: data\n```"
        let result = MarkdownRenderer.render(input)
        #expect(result.contains("    key: value"))
        #expect(result.contains("    other: data"))
    }

    @Test("code block fences are not included in output")
    func codeFencesRemoved() {
        let input = "```\nhello\n```"
        let result = MarkdownRenderer.render(input)
        #expect(!result.contains("```"))
    }

    // MARK: - Bold

    @Test("double asterisks render as ANSI bold")
    func boldText() {
        let result = MarkdownRenderer.render("This is **important** text.")
        #expect(result.contains("\(bold)important\(reset)"))
        #expect(!result.contains("**"))
    }

    @Test("multiple bold spans in one line")
    func multipleBoldSpans() {
        let result = MarkdownRenderer.render("**first** and **second**")
        #expect(result.contains("\(bold)first\(reset)"))
        #expect(result.contains("\(bold)second\(reset)"))
    }

    @Test("unclosed bold marker is left as-is")
    func unclosedBold() {
        let result = MarkdownRenderer.render("This is **not closed")
        #expect(result.contains("**not closed"))
    }

    // MARK: - Plain Text

    @Test("plain text passes through unchanged")
    func plainText() {
        let input = "Just a normal line of text."
        let result = MarkdownRenderer.render(input)
        #expect(result.contains(input))
    }

    @Test("table rows pass through")
    func tablePassthrough() {
        let input = "| Field | Type |\n|-------|------|\n| name  | string |"
        let result = MarkdownRenderer.render(input)
        #expect(result.contains("| Field | Type |"))
        #expect(result.contains("| name  | string |"))
    }
}
