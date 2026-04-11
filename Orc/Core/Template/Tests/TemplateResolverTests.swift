import Testing
import Models
@testable import Template

@Suite("TemplateResolver")
struct TemplateResolverTests {

    let resolver = TemplateResolver()

    // MARK: - Helpers

    /// Builds a minimal TaskContext with the given overrides.
    private func makeContext(
        inputs: [String: String] = [:],
        outputs: [String: String] = [:],
        nodeStatuses: [String: NodeStatus] = [:],
        workspacePath: String = "/workspace"
    ) -> TaskContext {
        TaskContext(
            inputs: inputs,
            outputs: outputs,
            nodeStatuses: nodeStatuses,
            workspacePath: workspacePath
        )
    }

    // MARK: - Input Variables

    @Test("Resolves an input variable")
    func resolveInput() throws {
        let ctx = makeContext(inputs: ["name": "Orc"])
        let result = try resolver.resolve(template: "Hello {{name}}!", context: ctx)
        #expect(result == "Hello Orc!")
    }

    // MARK: - Node Output

    @Test("Resolves a node.output reference")
    func resolveNodeOutput() throws {
        let ctx = makeContext(outputs: ["build": "success"])
        let result = try resolver.resolve(template: "Build: {{build.output}}", context: ctx)
        #expect(result == "Build: success")
    }

    // MARK: - Node Status

    @Test("Resolves a node.status reference")
    func resolveNodeStatus() throws {
        let ctx = makeContext(nodeStatuses: ["deploy": .completed])
        let result = try resolver.resolve(template: "Deploy is {{deploy.status}}", context: ctx)
        #expect(result == "Deploy is completed")
    }

    // MARK: - Output Alias

    @Test("Resolves an output alias stored in context.outputs")
    func resolveAlias() throws {
        let ctx = makeContext(outputs: ["summary": "All tests passed"])
        let result = try resolver.resolve(template: "Result: {{summary}}", context: ctx)
        #expect(result == "Result: All tests passed")
    }

    // MARK: - Workspace

    @Test("Resolves the {{workspace}} built-in")
    func resolveWorkspace() throws {
        let ctx = makeContext(workspacePath: "/Users/dev/project")
        let result = try resolver.resolve(template: "Path: {{workspace}}", context: ctx)
        #expect(result == "Path: /Users/dev/project")
    }

    // MARK: - Last Output

    @Test("Resolves {{last_output}} from context.outputs")
    func resolveLastOutput() throws {
        let ctx = makeContext(outputs: ["last_output": "42"])
        let result = try resolver.resolve(template: "Got: {{last_output}}", context: ctx)
        #expect(result == "Got: 42")
    }

    // MARK: - Escape Handling

    @Test("Escaped \\{{ produces literal {{")
    func escapeHandling() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(template: "Use \\{{var}} syntax", context: ctx)
        #expect(result == "Use {{var}} syntax")
    }

    // MARK: - Multiple Variables

    @Test("Resolves multiple variables in a single template")
    func multipleVariables() throws {
        let ctx = makeContext(
            inputs: ["user": "Alice"],
            outputs: ["task": "build"],
            workspacePath: "/ws"
        )
        let result = try resolver.resolve(
            template: "{{user}} ran {{task}} in {{workspace}}",
            context: ctx
        )
        #expect(result == "Alice ran build in /ws")
    }

    // MARK: - Passthrough

    @Test("Template with no variables passes through unchanged")
    func passthrough() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(template: "Hello world!", context: ctx)
        #expect(result == "Hello world!")
    }

    // MARK: - Empty Template

    @Test("Empty template resolves to empty string")
    func emptyTemplate() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(template: "", context: ctx)
        #expect(result == "")
    }

    // MARK: - Whitespace Trimming Inside Braces

    @Test("Whitespace inside {{ }} is trimmed")
    func whitespaceTrimming() throws {
        let ctx = makeContext(inputs: ["x": "1"])
        let result = try resolver.resolve(template: "{{ x }}", context: ctx)
        #expect(result == "1")
    }

    // MARK: - Error: Unresolved Variable

    @Test("Throws unresolvedVariable for unknown variable")
    func unresolvedVariable() throws {
        let ctx = makeContext()
        #expect(throws: TemplateError.unresolvedVariable(name: "missing")) {
            try resolver.resolve(template: "{{missing}}", context: ctx)
        }
    }

    @Test("Throws unresolvedVariable for unknown node.output")
    func unresolvedNodeOutput() throws {
        let ctx = makeContext()
        #expect(throws: TemplateError.unresolvedVariable(name: "unknown.output")) {
            try resolver.resolve(template: "{{unknown.output}}", context: ctx)
        }
    }

    @Test("Throws unresolvedVariable for unknown node.status")
    func unresolvedNodeStatus() throws {
        let ctx = makeContext()
        #expect(throws: TemplateError.unresolvedVariable(name: "unknown.status")) {
            try resolver.resolve(template: "{{unknown.status}}", context: ctx)
        }
    }

    @Test("Throws unresolvedVariable for missing last_output")
    func unresolvedLastOutput() throws {
        let ctx = makeContext()
        #expect(throws: TemplateError.unresolvedVariable(name: "last_output")) {
            try resolver.resolve(template: "{{last_output}}", context: ctx)
        }
    }

    // MARK: - Error: Malformed Template

    @Test("Throws malformedTemplate for unclosed {{")
    func malformedUnclosed() throws {
        let ctx = makeContext()
        #expect {
            try resolver.resolve(template: "Hello {{name", context: ctx)
        } throws: { error in
            guard let templateError = error as? TemplateError else { return false }
            if case .malformedTemplate = templateError { return true }
            return false
        }
    }

    @Test("Throws malformedTemplate for {{ at end of string")
    func malformedAtEnd() throws {
        let ctx = makeContext()
        #expect {
            try resolver.resolve(template: "Hello {{", context: ctx)
        } throws: { error in
            guard let templateError = error as? TemplateError else { return false }
            if case .malformedTemplate = templateError { return true }
            return false
        }
    }

    // MARK: - Default Filter

    @Test("Uses default value when variable is unresolved")
    func defaultFilterUnresolved() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(
            template: "{{greeting | default: Hello, World!}}",
            context: ctx
        )
        #expect(result == "Hello, World!")
    }

    @Test("Uses actual value when variable is resolved, ignoring default")
    func defaultFilterResolved() throws {
        let ctx = makeContext(inputs: ["greeting": "Hi there"])
        let result = try resolver.resolve(
            template: "{{greeting | default: Hello, World!}}",
            context: ctx
        )
        #expect(result == "Hi there")
    }

    @Test("Default filter with whitespace trimming")
    func defaultFilterWhitespace() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(
            template: "{{ name | default: anonymous }}",
            context: ctx
        )
        #expect(result == "anonymous")
    }

    @Test("Default filter with empty default value")
    func defaultFilterEmpty() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(
            template: "{{missing | default: }}",
            context: ctx
        )
        #expect(result == "")
    }
}
