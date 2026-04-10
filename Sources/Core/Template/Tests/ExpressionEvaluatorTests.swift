import Testing
import Models
@testable import Template

@Suite("ExpressionEvaluator")
struct ExpressionEvaluatorTests {

    let evaluator = ExpressionEvaluator()

    // MARK: - Helpers

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

    // MARK: - Simple Equality

    @Test("Status equals comparison — true")
    func statusEqualsTrue() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed])
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed'",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("Status equals comparison — false")
    func statusEqualsFalse() throws {
        let ctx = makeContext(nodeStatuses: ["a": .failed])
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed'",
            context: ctx
        )
        #expect(result == false)
    }

    // MARK: - Not-Equal

    @Test("Output not-equal comparison — true")
    func outputNotEqualTrue() throws {
        let ctx = makeContext(outputs: ["a": "no"])
        let result = try evaluator.evaluate(
            expression: "{{a.output}} != 'yes'",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("Output not-equal comparison — false")
    func outputNotEqualFalse() throws {
        let ctx = makeContext(outputs: ["a": "yes"])
        let result = try evaluator.evaluate(
            expression: "{{a.output}} != 'yes'",
            context: ctx
        )
        #expect(result == false)
    }

    // MARK: - Boolean AND

    @Test("AND — both true")
    func andBothTrue() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed, "b": .completed])
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed' && {{b.status}} == 'completed'",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("AND — one false")
    func andOneFalse() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed, "b": .failed])
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed' && {{b.status}} == 'completed'",
            context: ctx
        )
        #expect(result == false)
    }

    // MARK: - Boolean OR

    @Test("OR — one true")
    func orOneTrue() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed, "b": .failed])
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed' || {{b.status}} == 'completed'",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("OR — both false")
    func orBothFalse() throws {
        let ctx = makeContext(nodeStatuses: ["a": .failed, "b": .failed])
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed' || {{b.status}} == 'completed'",
            context: ctx
        )
        #expect(result == false)
    }

    // MARK: - Negation

    @Test("Negation of false comparison yields true")
    func negation() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed])
        let result = try evaluator.evaluate(
            expression: "!({{a.status}} == 'failed')",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("Negation of true comparison yields false")
    func negationFalse() throws {
        let ctx = makeContext(nodeStatuses: ["a": .failed])
        let result = try evaluator.evaluate(
            expression: "!({{a.status}} == 'failed')",
            context: ctx
        )
        #expect(result == false)
    }

    // MARK: - Grouping

    @Test("Grouped sub-expressions")
    func grouping() throws {
        let ctx = makeContext(
            outputs: ["b": "yes"],
            nodeStatuses: ["a": .completed]
        )
        let result = try evaluator.evaluate(
            expression: "({{a.status}} == 'completed') && ({{b.output}} == 'yes')",
            context: ctx
        )
        #expect(result == true)
    }

    // MARK: - Precedence

    @Test("AND binds tighter than OR")
    func precedence() throws {
        // Expression: a == 'completed' && b == 'completed' || c == 'completed'
        // Parsed as: (a == 'completed' && b == 'completed') || c == 'completed'
        // a=failed, b=failed, c=completed → false && false || true → true
        let ctx = makeContext(
            nodeStatuses: ["a": .failed, "b": .failed, "c": .completed]
        )
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed' && {{b.status}} == 'completed' || {{c.status}} == 'completed'",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("Precedence: AND before OR — both AND operands true")
    func precedenceAndTrue() throws {
        // a=completed, b=completed, c=failed
        // (completed == completed && completed == completed) || failed == completed
        // (true && true) || false → true
        let ctx = makeContext(
            nodeStatuses: ["a": .completed, "b": .completed, "c": .failed]
        )
        let result = try evaluator.evaluate(
            expression: "{{a.status}} == 'completed' && {{b.status}} == 'completed' || {{c.status}} == 'completed'",
            context: ctx
        )
        #expect(result == true)
    }

    // MARK: - Complex Expression

    @Test("Complex nested expression")
    func complexExpression() throws {
        let ctx = makeContext(
            outputs: ["b": "yes"],
            nodeStatuses: ["a": .completed, "c": .failed]
        )
        // (completed == 'completed') && (yes == 'yes' || failed == 'completed')
        // true && (true || false) → true
        let result = try evaluator.evaluate(
            expression: "({{a.status}} == 'completed') && ({{b.output}} == 'yes' || {{c.status}} == 'completed')",
            context: ctx
        )
        #expect(result == true)
    }

    // MARK: - Edge Cases

    @Test("Comparison with empty string literal")
    func emptyStringLiteral() throws {
        let ctx = makeContext(outputs: ["a": ""])
        let result = try evaluator.evaluate(
            expression: "{{a.output}} == ''",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("Bare value truthiness — non-empty string is truthy")
    func bareValueTruthy() throws {
        let ctx = makeContext(outputs: ["a": "hello"])
        let result = try evaluator.evaluate(
            expression: "{{a.output}}",
            context: ctx
        )
        #expect(result == true)
    }

    @Test("Bare value truthiness — 'false' string is falsy")
    func bareValueFalseString() throws {
        let ctx = makeContext(outputs: ["a": "false"])
        let result = try evaluator.evaluate(
            expression: "{{a.output}}",
            context: ctx
        )
        #expect(result == false)
    }

    @Test("Bare value truthiness — empty string is falsy")
    func bareValueEmpty() throws {
        let ctx = makeContext(outputs: ["a": ""])
        let result = try evaluator.evaluate(
            expression: "{{a.output}}",
            context: ctx
        )
        #expect(result == false)
    }

    // MARK: - Syntax Errors

    @Test("Syntax error — missing right operand")
    func syntaxErrorMissingOperand() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed])
        #expect {
            try evaluator.evaluate(
                expression: "{{a.status}} ==",
                context: ctx
            )
        } throws: { error in
            guard let templateError = error as? TemplateError else { return false }
            if case .expressionSyntax = templateError { return true }
            return false
        }
    }

    @Test("Syntax error — unclosed parenthesis")
    func syntaxErrorUnclosedParen() throws {
        let ctx = makeContext(nodeStatuses: ["a": .completed])
        #expect {
            try evaluator.evaluate(
                expression: "({{a.status}} == 'completed'",
                context: ctx
            )
        } throws: { error in
            guard let templateError = error as? TemplateError else { return false }
            if case .expressionSyntax = templateError { return true }
            return false
        }
    }

    @Test("Syntax error — unexpected token")
    func syntaxErrorUnexpectedToken() throws {
        let ctx = makeContext()
        #expect {
            try evaluator.evaluate(
                expression: "== 'value'",
                context: ctx
            )
        } throws: { error in
            guard let templateError = error as? TemplateError else { return false }
            if case .expressionSyntax = templateError { return true }
            return false
        }
    }

    // MARK: - Unresolved Variable in Expression

    @Test("Unresolved variable in expression throws")
    func unresolvedVariableInExpression() throws {
        let ctx = makeContext()
        #expect {
            try evaluator.evaluate(
                expression: "{{missing}} == 'value'",
                context: ctx
            )
        } throws: { error in
            guard let templateError = error as? TemplateError else { return false }
            if case .unresolvedVariable = templateError { return true }
            return false
        }
    }
}
