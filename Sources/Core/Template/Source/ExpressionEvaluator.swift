import Models

/// Evaluates boolean `when:` guard expressions against the current `TaskContext`.
///
/// The evaluator first resolves all `{{…}}` template variables, then tokenizes,
/// parses an AST, and evaluates it to a boolean result.
///
/// Supported syntax:
/// - Comparisons: `==`, `!=` (string-based)
/// - Boolean operators: `&&`, `||`
/// - Negation: `!`
/// - Grouping: `(`, `)`
/// - String literals: `'value'` (with `\'` escape for embedded quotes)
/// - Bare values: resolved template strings (after variable substitution)
///
/// Operator precedence (low → high): `||`, `&&`, `!`, comparisons
struct ExpressionEvaluator: ExpressionEvaluating, Sendable {

    init() {}

    func evaluate(expression: String, context: TaskContext) throws -> Bool {
        // Step 1: Resolve all {{…}} variables into quoted string literals.
        // This ensures empty values and values containing spaces or operators
        // are correctly tokenized (e.g., "" becomes '' instead of invisible whitespace).
        let resolved = try resolveForExpression(expression: expression, context: context)

        // Step 2: Tokenize
        let tokens = try ExpressionHelper.tokenize(resolved)

        // Step 3: Parse into AST
        var parser = ExpressionParser(tokens: tokens)
        let ast = try parser.parseExpression()

        // Ensure all tokens were consumed
        if parser.currentIndex < tokens.count {
            throw TemplateError.expressionSyntax(
                detail: "Unexpected token '\(tokens[parser.currentIndex])' after expression")
        }

        // Step 4: Evaluate AST
        return ExpressionHelper.evaluateNode(ast)
    }

    // MARK: - Private Helpers

    /// Resolves `{{…}}` variables in an expression, wrapping each resolved value
    /// in single quotes so the tokenizer treats them as string literals.
    /// This handles empty values (which would be invisible as bare strings)
    /// and values containing whitespace or operator characters.
    private func resolveForExpression(expression: String, context: TaskContext) throws -> String {
        let resolver = TemplateResolver()
        var result = ""
        let chars = Array(expression.unicodeScalars)
        let count = chars.count
        var i = 0

        while i < count {
            // Escaped opening brace: \{{ → pass through as-is (will be literal text)
            if chars[i] == "\\" && i + 2 < count && chars[i + 1] == "{" && chars[i + 2] == "{" {
                // Escaped braces shouldn't appear in expressions, but pass through
                result.append("\\{{")
                i += 3
                continue
            }

            // Start of a variable placeholder
            if chars[i] == "{" && i + 1 < count && chars[i + 1] == "{" {
                guard let closeIndex = findClosingBraces(chars, from: i + 2) else {
                    throw TemplateError.malformedTemplate(
                        detail: "Unclosed '{{' near position \(i)")
                }

                // Extract the full {{…}} and resolve it
                let startIdx = expression.index(expression.startIndex, offsetBy: i)
                let endIdx = expression.index(expression.startIndex, offsetBy: closeIndex + 2)
                let placeholder = String(expression[startIdx..<endIdx])
                let resolved = try resolver.resolve(template: placeholder, context: context)

                // Wrap in single quotes, escaping any single quotes in the value
                let escaped = resolved.replacingOccurrences(of: "'", with: "\\'")
                result.append("'\(escaped)'")
                i = closeIndex + 2
                continue
            }

            result.append(String(chars[i]))
            i += 1
        }

        return result
    }

    /// Scans forward from `start` looking for `}}`. Returns the index of the first `}` in `}}`.
    private func findClosingBraces(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "}" && chars[j + 1] == "}" {
                return j
            }
            j += 1
        }
        return nil
    }
}

// MARK: - Factory

/// Factory for creating `ExpressionEvaluating` instances.
///
/// The concrete `ExpressionEvaluator` type is `internal`; callers across module
/// boundaries access it through this factory and the `ExpressionEvaluating` protocol.
public enum ExpressionFactory {
    public static func makeEvaluator() -> any ExpressionEvaluating {
        ExpressionEvaluator()
    }
}

/// Creates an `ExpressionEvaluating` instance.
@available(*, deprecated, message: "Use ExpressionFactory.makeEvaluator() instead")
public func makeExpressionEvaluator() -> any ExpressionEvaluating {
    ExpressionFactory.makeEvaluator()
}

// MARK: - Token

/// A single lexical token in a `when:` expression.
enum Token: Sendable, Equatable, CustomStringConvertible {
    case stringLiteral(String)
    case bareValue(String)
    case equals       // ==
    case notEquals    // !=
    case and          // &&
    case or           // ||
    case not          // !
    case leftParen    // (
    case rightParen   // )

    var description: String {
        switch self {
        case .stringLiteral(let s): return "'\(s)'"
        case .bareValue(let s):     return s
        case .equals:               return "=="
        case .notEquals:            return "!="
        case .and:                  return "&&"
        case .or:                   return "||"
        case .not:                  return "!"
        case .leftParen:            return "("
        case .rightParen:           return ")"
        }
    }
}

// MARK: - Tokenizer

/// Namespace for expression tokenization and AST evaluation helpers.
///
/// These are grouped in a caseless enum to avoid polluting the file scope
/// with free functions while keeping them accessible to both
/// `ExpressionEvaluator` and `ExpressionParser`.
private enum ExpressionHelper {

    /// Tokenizes a resolved expression string into a sequence of `Token` values.
    static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input.unicodeScalars)
        let count = chars.count
        var i = 0

        while i < count {
            let ch = chars[i]

            // Skip whitespace
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                i += 1
                continue
            }

            // String literal: 'value' with \' escape
            if ch == "'" {
                i += 1
                var literal = ""
                while i < count {
                    if chars[i] == "\\" && i + 1 < count && chars[i + 1] == "'" {
                        literal.append("'")
                        i += 2
                    } else if chars[i] == "'" {
                        break
                    } else {
                        literal.append(String(chars[i]))
                        i += 1
                    }
                }
                guard i < count && chars[i] == "'" else {
                    throw TemplateError.expressionSyntax(detail: "Unterminated string literal")
                }
                i += 1  // skip closing quote
                tokens.append(.stringLiteral(literal))
                continue
            }

            // Two-character operators
            if i + 1 < count {
                let next = chars[i + 1]
                if ch == "=" && next == "=" {
                    tokens.append(.equals)
                    i += 2
                    continue
                }
                if ch == "!" && next == "=" {
                    tokens.append(.notEquals)
                    i += 2
                    continue
                }
                if ch == "&" && next == "&" {
                    tokens.append(.and)
                    i += 2
                    continue
                }
                if ch == "|" && next == "|" {
                    tokens.append(.or)
                    i += 2
                    continue
                }
            }

            // Single-character operators
            if ch == "!" {
                tokens.append(.not)
                i += 1
                continue
            }
            if ch == "(" {
                tokens.append(.leftParen)
                i += 1
                continue
            }
            if ch == ")" {
                tokens.append(.rightParen)
                i += 1
                continue
            }

            // Bare value: everything up to the next operator, paren, quote, or whitespace
            var bare = ""
            while i < count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    break
                }
                if c == "'" || c == "(" || c == ")" {
                    break
                }
                // Check for two-character operators
                if i + 1 < count {
                    let n = chars[i + 1]
                    if (c == "=" && n == "=") || (c == "!" && n == "=")
                        || (c == "&" && n == "&") || (c == "|" && n == "|")
                    {
                        break
                    }
                }
                // Single `!` at start of a bare token is an operator, not part of the value.
                // But if we already have content, `!` is just a character in the value.
                if c == "!" && bare.isEmpty {
                    break
                }
                bare.append(String(c))
                i += 1
            }
            if !bare.isEmpty {
                tokens.append(.bareValue(bare))
            }
        }

        return tokens
    }

    /// Evaluates an `Expression` AST to a boolean result.
    ///
    /// - Comparisons use string equality/inequality.
    /// - `.value(s)` is truthy when `s` is non-empty and not `"false"`.
    static func evaluateNode(_ node: Expression) -> Bool {
        switch node {
        case .comparison(let left, let op, let right):
            switch op {
            case .equal:    return left == right
            case .notEqual: return left != right
            }

        case .and(let lhs, let rhs):
            return evaluateNode(lhs) && evaluateNode(rhs)

        case .or(let lhs, let rhs):
            return evaluateNode(lhs) || evaluateNode(rhs)

        case .not(let inner):
            return !evaluateNode(inner)

        case .value(let s):
            // A bare value is truthy when non-empty and not literally "false"
            return !s.isEmpty && s != "false"
        }
    }
}

// MARK: - AST

/// The comparison operator used in a binary expression node.
enum ComparisonOp: Sendable {
    case equal
    case notEqual
}

/// An expression node in the abstract syntax tree.
indirect enum Expression: Sendable {
    case comparison(left: String, op: ComparisonOp, right: String)
    case and(Expression, Expression)
    case or(Expression, Expression)
    case not(Expression)
    case value(String)
}

// MARK: - Parser

/// Recursive-descent parser that builds an `Expression` AST from a token stream.
///
/// Precedence (low → high): `||`, `&&`, `!`, comparison/primary
struct ExpressionParser {
    let tokens: [Token]
    var currentIndex: Int = 0

    /// Returns the token at the current position, or `nil` if exhausted.
    private var current: Token? {
        currentIndex < tokens.count ? tokens[currentIndex] : nil
    }

    /// Advances past the current token and returns it.
    @discardableResult
    private mutating func advance() -> Token? {
        guard currentIndex < tokens.count else { return nil }
        let tok = tokens[currentIndex]
        currentIndex += 1
        return tok
    }

    // MARK: - Grammar rules

    /// expression = orExpr
    mutating func parseExpression() throws -> Expression {
        try parseOr()
    }

    /// orExpr = andExpr ( '||' andExpr )*
    private mutating func parseOr() throws -> Expression {
        var left = try parseAnd()
        while current == .or {
            advance()
            let right = try parseAnd()
            left = .or(left, right)
        }
        return left
    }

    /// andExpr = unaryExpr ( '&&' unaryExpr )*
    private mutating func parseAnd() throws -> Expression {
        var left = try parseUnary()
        while current == .and {
            advance()
            let right = try parseUnary()
            left = .and(left, right)
        }
        return left
    }

    /// unaryExpr = '!' unaryExpr | comparison
    private mutating func parseUnary() throws -> Expression {
        if current == .not {
            advance()
            let operand = try parseUnary()
            return .not(operand)
        }
        return try parseComparison()
    }

    /// comparison = primary ( ('==' | '!=') primary )?
    private mutating func parseComparison() throws -> Expression {
        let left = try parsePrimary()

        if current == .equals {
            advance()
            let right = try parsePrimary()
            let leftStr = try stringValue(left)
            let rightStr = try stringValue(right)
            return .comparison(left: leftStr, op: .equal, right: rightStr)
        }
        if current == .notEquals {
            advance()
            let right = try parsePrimary()
            let leftStr = try stringValue(left)
            let rightStr = try stringValue(right)
            return .comparison(left: leftStr, op: .notEqual, right: rightStr)
        }

        return left
    }

    /// primary = '(' expression ')' | stringLiteral | bareValue
    private mutating func parsePrimary() throws -> Expression {
        guard let tok = current else {
            throw TemplateError.expressionSyntax(detail: "Unexpected end of expression")
        }

        switch tok {
        case .leftParen:
            advance()
            let expr = try parseExpression()
            guard current == .rightParen else {
                throw TemplateError.expressionSyntax(detail: "Expected ')' to close group")
            }
            advance()
            return expr

        case .stringLiteral(let s):
            advance()
            return .value(s)

        case .bareValue(let s):
            advance()
            return .value(s)

        default:
            throw TemplateError.expressionSyntax(
                detail: "Unexpected token '\(tok)' in expression")
        }
    }

    /// Extracts the string representation from a value-like expression node.
    ///
    /// Throws `.expressionEvaluation` if a non-value expression (e.g., a boolean
    /// sub-expression like `(a && b)`) is used as a comparison operand, which
    /// indicates a runtime type mismatch rather than a syntax error.
    private func stringValue(_ expr: Expression) throws -> String {
        if case .value(let s) = expr { return s }
        throw TemplateError.expressionEvaluation(
            detail: "Cannot compare non-string expression — operand must be a value, not a boolean sub-expression"
        )
    }
}

