import Models

/// Resolves `{{variable}}` placeholders in template strings using the current `TaskContext`.
///
/// Resolution rules (applied in a single left-to-right pass):
/// - `\{{` → literal `{{` (escape)
/// - `{{input_name}}` → `context.inputs[input_name]`
/// - `{{node_id.output}}` → `context.outputs[node_id]`
/// - `{{node_id.status}}` → `context.nodeStatuses[node_id]?.rawValue`
/// - `{{workspace}}` → `context.workspacePath`
/// - `{{last_output}}` → `context.outputs["last_output"]`
/// - Otherwise → `context.outputs[name]` (handles aliases)
/// - Unresolved → throws `TemplateError.unresolvedVariable`
/// - Unclosed `{{` → throws `TemplateError.malformedTemplate`
struct TemplateResolver: TemplateResolving, Sendable {

    init() {}

    func resolve(template: String, context: TaskContext) throws -> String {
        var result = ""
        let chars = Array(template.unicodeScalars)
        let count = chars.count
        var i = 0

        while i < count {
            // Escaped opening brace: \{{ → literal {{
            if chars[i] == "\\" && i + 2 < count && chars[i + 1] == "{" && chars[i + 2] == "{" {
                result.append("{{")
                i += 3
                continue
            }

            // Start of a variable placeholder
            if chars[i] == "{" && i + 1 < count && chars[i + 1] == "{" {
                // Find the closing }}
                guard let closeIndex = findClosingBraces(chars, from: i + 2) else {
                    throw TemplateError.malformedTemplate(detail: "Unclosed '{{' near position \(i)")
                }

                let variableName = String(
                    template[
                        template.index(template.startIndex, offsetBy: i + 2)..<template.index(
                            template.startIndex, offsetBy: closeIndex)
                    ]
                ).trimmingCharacters(in: .whitespaces)

                let resolved = try resolveVariable(variableName, context: context)
                result.append(resolved)
                i = closeIndex + 2  // skip past }}
                continue
            }

            result.append(String(chars[i]))
            i += 1
        }

        return result
    }

    // MARK: - Private Helpers

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

    /// Resolves a single variable name against the task context.
    private func resolveVariable(_ name: String, context: TaskContext) throws -> String {
        // Check for dot-qualified references: node_id.output or node_id.status
        if let dotIndex = name.firstIndex(of: ".") {
            let prefix = String(name[name.startIndex..<dotIndex])
            let suffix = String(name[name.index(after: dotIndex)...])

            switch suffix {
            case "output":
                if let value = context.outputs[prefix] {
                    return value
                }
                throw TemplateError.unresolvedVariable(name: name)

            case "status":
                if let status = context.nodeStatuses[prefix] {
                    return status.rawValue
                }
                throw TemplateError.unresolvedVariable(name: name)

            default:
                // Unknown qualifier — treat entire name as a lookup key
                break
            }
        }

        // Built-in variables
        if name == "workspace" {
            return context.workspacePath
        }
        if name == "last_output" {
            if let value = context.outputs["last_output"] {
                return value
            }
            throw TemplateError.unresolvedVariable(name: name)
        }

        // Direct input lookup
        if let value = context.inputs[name] {
            return value
        }

        // Output/alias lookup (engine stores output aliases in context.outputs)
        if let value = context.outputs[name] {
            return value
        }

        throw TemplateError.unresolvedVariable(name: name)
    }
}

// MARK: - Factory

/// Factory for creating `TemplateResolving` instances.
///
/// The concrete `TemplateResolver` type is `internal`; callers across module
/// boundaries access it through this factory and the `TemplateResolving` protocol.
public enum TemplateFactory {
    public static func makeResolver() -> any TemplateResolving {
        TemplateResolver()
    }
}

/// Creates a `TemplateResolving` instance.
@available(*, deprecated, message: "Use TemplateFactory.makeResolver() instead")
public func makeTemplateResolver() -> any TemplateResolving {
    TemplateFactory.makeResolver()
}
