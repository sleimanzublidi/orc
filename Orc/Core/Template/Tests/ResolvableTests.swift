import Testing
import Foundation
import Models
@testable import Template

@Suite("Resolvable")
struct ResolvableTests {

    let resolver = TemplateResolver()

    // MARK: - Helpers

    private func makeContext(
        inputs: [String: String] = [:],
        outputs: [String: String] = [:]
    ) -> TaskContext {
        TaskContext(
            inputs: inputs,
            outputs: outputs,
            nodeStatuses: [:],
            repoRoot: "/tmp/repo",
            workspacePath: "/workspace"
        )
    }

    // MARK: - Resolvable<T> Enum Basics

    @Test("Literal value is accessible via literalValue")
    func literalAccessor() {
        let r = Resolvable<Int>.literal(42)
        #expect(r.literalValue == 42)
        #expect(r.templateExpression == nil)
    }

    @Test("Template expression is accessible via templateExpression")
    func templateAccessor() {
        let r = Resolvable<Int>.template("{{count}}")
        #expect(r.templateExpression == "{{count}}")
        #expect(r.literalValue == nil)
    }

    @Test("Literal values are Equatable")
    func literalEquality() {
        #expect(Resolvable<String>.literal("a") == Resolvable<String>.literal("a"))
        #expect(Resolvable<String>.literal("a") != Resolvable<String>.literal("b"))
    }

    @Test("Template values are Equatable")
    func templateEquality() {
        #expect(Resolvable<Int>.template("{{x}}") == Resolvable<Int>.template("{{x}}"))
        #expect(Resolvable<Int>.template("{{x}}") != Resolvable<Int>.template("{{y}}"))
    }

    @Test("Literal and template are not equal even with same underlying")
    func literalVsTemplate() {
        // A literal string "hello" and a template "hello" are different variants
        #expect(Resolvable<String>.literal("hello") != Resolvable<String>.template("hello"))
    }

    // MARK: - Codable Round-Trip

    @Test("Resolvable<Int> literal round-trips through JSON")
    func codableIntLiteral() throws {
        let original = Resolvable<Int>.literal(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Resolvable<Int>.self, from: data)
        #expect(decoded == original)
    }

    @Test("Resolvable<String> literal round-trips through JSON")
    func codableStringLiteral() throws {
        let original = Resolvable<String>.literal("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Resolvable<String>.self, from: data)
        #expect(decoded == original)
    }

    @Test("Resolvable<Int> template decodes from string")
    func codableIntTemplate() throws {
        // "{{count}}" is not a valid Int, so it should decode as .template
        let json = Data("\"{{count}}\"".utf8)
        let decoded = try JSONDecoder().decode(Resolvable<Int>.self, from: json)
        #expect(decoded == .template("{{count}}"))
    }

    @Test("Resolvable<String> with {{…}} decodes as template, not literal")
    func codableStringTemplate() throws {
        let json = Data("\"{{agent_name}}\"".utf8)
        let decoded = try JSONDecoder().decode(Resolvable<String>.self, from: json)
        #expect(decoded == .template("{{agent_name}}"))
    }

    @Test("Resolvable<Bool> literal round-trips through JSON")
    func codableBoolLiteral() throws {
        let original = Resolvable<Bool>.literal(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Resolvable<Bool>.self, from: data)
        #expect(decoded == original)
    }

    @Test("Resolvable<FailureStrategy> literal round-trips through JSON")
    func codableFailureStrategyLiteral() throws {
        let original = Resolvable<FailureStrategy>.literal(.skip)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Resolvable<FailureStrategy>.self, from: data)
        #expect(decoded == original)
    }

    @Test("Resolvable<FailureStrategy> template decodes from string with {{…}}")
    func codableFailureStrategyTemplate() throws {
        let json = Data("\"{{on_fail}}\"".utf8)
        let decoded = try JSONDecoder().decode(Resolvable<FailureStrategy>.self, from: json)
        #expect(decoded == .template("{{on_fail}}"))
    }

    // MARK: - Resolve: Literal Pass-Through

    @Test("Resolving a literal Int returns the value directly")
    func resolveLiteralInt() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(Resolvable<Int>.literal(42), context: ctx)
        #expect(result == 42)
    }

    @Test("Resolving a literal String returns the value directly")
    func resolveLiteralString() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(Resolvable<String>.literal("hello"), context: ctx)
        #expect(result == "hello")
    }

    @Test("Resolving a literal Bool returns the value directly")
    func resolveLiteralBool() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(Resolvable<Bool>.literal(false), context: ctx)
        #expect(result == false)
    }

    @Test("Resolving a literal FailureStrategy returns the value directly")
    func resolveLiteralFailureStrategy() throws {
        let ctx = makeContext()
        let result = try resolver.resolve(Resolvable<FailureStrategy>.literal(.skip), context: ctx)
        #expect(result == .skip)
    }

    // MARK: - Resolve: Template -> String

    @Test("Resolving a template String substitutes from context")
    func resolveTemplateString() throws {
        let ctx = makeContext(inputs: ["name": "claude"])
        let result = try resolver.resolve(Resolvable<String>.template("{{name}}"), context: ctx)
        #expect(result == "claude")
    }

    @Test("Resolving a template String with multiple variables")
    func resolveTemplateStringMultiple() throws {
        let ctx = makeContext(inputs: ["first": "hello", "second": "world"])
        let result = try resolver.resolve(
            Resolvable<String>.template("{{first}}-{{second}}"),
            context: ctx
        )
        #expect(result == "hello-world")
    }

    // MARK: - Resolve: Template -> Int

    @Test("Resolving a template Int converts from context string")
    func resolveTemplateInt() throws {
        let ctx = makeContext(inputs: ["timeout": "30"])
        let result = try resolver.resolve(Resolvable<Int>.template("{{timeout}}"), context: ctx)
        #expect(result == 30)
    }

    @Test("Resolving a template Int with non-numeric value throws invalidConversion")
    func resolveTemplateIntInvalid() throws {
        let ctx = makeContext(inputs: ["timeout": "abc"])
        #expect(throws: TemplateError.invalidConversion(value: "abc", targetType: "Int")) {
            try resolver.resolve(Resolvable<Int>.template("{{timeout}}"), context: ctx)
        }
    }

    // MARK: - Resolve: Template -> Bool

    @Test("Resolving a template Bool converts 'true'")
    func resolveTemplateBoolTrue() throws {
        let ctx = makeContext(inputs: ["flag": "true"])
        let result = try resolver.resolve(Resolvable<Bool>.template("{{flag}}"), context: ctx)
        #expect(result == true)
    }

    @Test("Resolving a template Bool converts 'false'")
    func resolveTemplateBoolFalse() throws {
        let ctx = makeContext(inputs: ["flag": "false"])
        let result = try resolver.resolve(Resolvable<Bool>.template("{{flag}}"), context: ctx)
        #expect(result == false)
    }

    @Test("Resolving a template Bool converts 'yes'/'no'")
    func resolveTemplateBoolYesNo() throws {
        let ctx = makeContext(inputs: ["a": "yes", "b": "no"])
        #expect(try resolver.resolve(Resolvable<Bool>.template("{{a}}"), context: ctx) == true)
        #expect(try resolver.resolve(Resolvable<Bool>.template("{{b}}"), context: ctx) == false)
    }

    @Test("Resolving a template Bool converts '1'/'0'")
    func resolveTemplateBoolOneZero() throws {
        let ctx = makeContext(inputs: ["a": "1", "b": "0"])
        #expect(try resolver.resolve(Resolvable<Bool>.template("{{a}}"), context: ctx) == true)
        #expect(try resolver.resolve(Resolvable<Bool>.template("{{b}}"), context: ctx) == false)
    }

    @Test("Resolving a template Bool is case-insensitive")
    func resolveTemplateBoolCaseInsensitive() throws {
        let ctx = makeContext(inputs: ["flag": "TRUE"])
        let result = try resolver.resolve(Resolvable<Bool>.template("{{flag}}"), context: ctx)
        #expect(result == true)
    }

    @Test("Resolving a template Bool with invalid value throws invalidConversion")
    func resolveTemplateBoolInvalid() throws {
        let ctx = makeContext(inputs: ["flag": "maybe"])
        #expect(throws: TemplateError.invalidConversion(value: "maybe", targetType: "Bool")) {
            try resolver.resolve(Resolvable<Bool>.template("{{flag}}"), context: ctx)
        }
    }

    // MARK: - Resolve: Template -> FailureStrategy

    @Test("Resolving a template FailureStrategy from context")
    func resolveTemplateFailureStrategy() throws {
        let ctx = makeContext(inputs: ["on_fail": "skip"])
        let result = try resolver.resolve(
            Resolvable<FailureStrategy>.template("{{on_fail}}"),
            context: ctx
        )
        #expect(result == .skip)
    }

    @Test("Resolving a template FailureStrategy with invalid value throws")
    func resolveTemplateFailureStrategyInvalid() throws {
        let ctx = makeContext(inputs: ["on_fail": "explode"])
        #expect(throws: TemplateError.invalidConversion(value: "explode", targetType: "FailureStrategy")) {
            try resolver.resolve(Resolvable<FailureStrategy>.template("{{on_fail}}"), context: ctx)
        }
    }

    // MARK: - Resolve: Template -> WorkspaceMode

    @Test("Resolving a template WorkspaceMode from context")
    func resolveTemplateWorkspaceMode() throws {
        let ctx = makeContext(inputs: ["ws": "isolated"])
        let result = try resolver.resolve(
            Resolvable<WorkspaceMode>.template("{{ws}}"),
            context: ctx
        )
        #expect(result == .isolated)
    }

    @Test("Resolving a template WorkspaceMode with invalid value throws")
    func resolveTemplateWorkspaceModeInvalid() throws {
        let ctx = makeContext(inputs: ["ws": "unknown"])
        #expect(throws: TemplateError.invalidConversion(value: "unknown", targetType: "WorkspaceMode")) {
            try resolver.resolve(Resolvable<WorkspaceMode>.template("{{ws}}"), context: ctx)
        }
    }

    // MARK: - Resolve: Unresolved Variable

    @Test("Resolving a template with missing variable throws unresolvedVariable")
    func resolveTemplateMissingVar() throws {
        let ctx = makeContext()
        #expect(throws: TemplateError.unresolvedVariable(name: "missing")) {
            try resolver.resolve(Resolvable<String>.template("{{missing}}"), context: ctx)
        }
    }

    // MARK: - Node Model Integration

    @Test("Node with literal agent value")
    func nodeWithLiteralAgent() {
        let node = Node(id: "test", agent: .literal("claude"))
        #expect(node.agent?.literalValue == "claude")
    }

    @Test("Node with template agent value")
    func nodeWithTemplateAgent() {
        let node = Node(id: "test", agent: .template("{{agent_name}}"))
        #expect(node.agent?.templateExpression == "{{agent_name}}")
    }

    @Test("Node defaults: onFailure is literal .stop")
    func nodeDefaults() {
        let node = Node(id: "test")
        #expect(node.onFailure == .literal(.stop))
    }

    @Test("LoopConfig defaults use literals")
    func loopConfigDefaults() {
        let loop = LoopConfig(until: "done == true")
        #expect(loop.maxIterations == .literal(10))
        #expect(loop.freshContext == .literal(false))
    }

    @Test("RetryConfig defaults use literals")
    func retryConfigDefaults() {
        let retry = RetryConfig()
        #expect(retry.maxAttempts == .literal(1))
        #expect(retry.delaySeconds == .literal(0))
    }

    @Test("LoopConfig with template maxIterations")
    func loopConfigTemplate() {
        let loop = LoopConfig(
            until: "done == true",
            maxIterations: .template("{{max_iters}}")
        )
        #expect(loop.maxIterations.templateExpression == "{{max_iters}}")
    }

    @Test("RetryConfig with template values")
    func retryConfigTemplate() {
        let retry = RetryConfig(
            maxAttempts: .template("{{retries}}"),
            delaySeconds: .template("{{delay}}")
        )
        #expect(retry.maxAttempts.templateExpression == "{{retries}}")
        #expect(retry.delaySeconds.templateExpression == "{{delay}}")
    }

    // MARK: - WorkflowInput defaultValue

    @Test("WorkflowInput with defaultValue")
    func workflowInputDefault() {
        let input = WorkflowInput(name: "agent", defaultValue: "claude")
        #expect(input.defaultValue == "claude")
    }

    @Test("WorkflowInput without defaultValue")
    func workflowInputNoDefault() {
        let input = WorkflowInput(name: "agent")
        #expect(input.defaultValue == nil)
    }

    @Test("WorkflowInput defaultValue encodes as 'default' key")
    func workflowInputDefaultCoding() throws {
        let input = WorkflowInput(name: "timeout", type: "string", required: false, defaultValue: "30")
        let data = try JSONEncoder().encode(input)
        // Decode as generic JSON to check key names — [String: Any] is not Decodable,
        // so we use JSONSerialization to inspect the raw keys.
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["default"] as? String == "30")
        #expect(json["name"] as? String == "timeout")
    }

    @Test("WorkflowInput decodes 'default' key as defaultValue")
    func workflowInputDefaultDecoding() throws {
        let json = Data("""
        {"name": "count", "type": "string", "required": true, "default": "5"}
        """.utf8)
        let input = try JSONDecoder().decode(WorkflowInput.self, from: json)
        #expect(input.defaultValue == "5")
    }
}
