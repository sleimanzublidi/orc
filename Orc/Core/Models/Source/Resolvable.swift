// MARK: - Resolvable

/// A value that is either a fixed literal or a template expression
/// requiring runtime resolution against a `TaskContext`.
///
/// Use `.literal(value)` for statically known values (e.g., parsed from YAML
/// without any `{{…}}` placeholders). Use `.template(expression)` for values
/// containing `{{…}}` that must be resolved at execution time.
///
/// The `Resolvable` type lives in `Models` (the leaf module) so that `Node`,
/// `LoopConfig`, and `RetryConfig` can reference it without importing `Template`.
/// Actual resolution logic lives in the `Template` module.
public enum Resolvable<T: Sendable & Equatable & Codable>: Sendable, Equatable {
    /// A statically known value — no template resolution needed.
    case literal(T)
    /// A template expression (e.g., `"{{input.timeout}}"`) that must be
    /// resolved against a `TaskContext` at runtime.
    case template(String)
}

// MARK: - Codable

extension Resolvable: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try decoding as the underlying type first (literal path).
        if let value = try? container.decode(T.self) {
            // Guard against strings that look like template expressions.
            // If the decoded value is a String containing "{{", treat it as a template.
            if let stringValue = value as? String, stringValue.contains("{{") {
                self = .template(stringValue)
            } else {
                self = .literal(value)
            }
            return
        }

        // Fall back to String decoding (template path).
        let stringValue = try container.decode(String.self)
        self = .template(stringValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .literal(let value):
            try container.encode(value)
        case .template(let expression):
            try container.encode(expression)
        }
    }
}

// MARK: - Convenience

extension Resolvable {
    /// Returns the literal value if this is a `.literal`, otherwise `nil`.
    public var literalValue: T? {
        switch self {
        case .literal(let value): return value
        case .template: return nil
        }
    }

    /// Returns the template expression if this is a `.template`, otherwise `nil`.
    public var templateExpression: String? {
        switch self {
        case .literal: return nil
        case .template(let expression): return expression
        }
    }
}

// MARK: - ResolvableConvertible

/// Types conforming to `ResolvableConvertible` can be converted from
/// a resolved `String` value. This protocol enables `TemplateResolver`
/// to resolve `Resolvable<T>` templates into concrete `T` values.
///
/// Conformances live in the `Template` module (not `Models`) because
/// conversion errors reference `TemplateError`, which is defined in `Template`.
public protocol ResolvableConvertible: Sendable, Equatable, Codable {
    /// Creates an instance from a resolved template string.
    /// Throws if the string cannot be converted to `Self`.
    static func fromResolved(_ string: String) throws -> Self
}
