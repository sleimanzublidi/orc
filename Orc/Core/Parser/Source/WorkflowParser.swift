import Foundation
import Models
import Template
import Yams


/// Parses YAML workflow definitions into validated `Workflow` model instances.
///
/// Uses manual dictionary mapping (not `Codable`) for better error messages
/// when required fields are missing or values are invalid.
struct WorkflowParser: WorkflowParsing, Sendable {

    init() {}

    // MARK: - WorkflowParsing

    /// Parses a YAML string into a validated `Workflow`.
    ///
    /// - Parameter yaml: A YAML-encoded workflow definition.
    /// - Returns: A fully populated `Workflow` value.
    /// - Throws: `ParserError` if the YAML is malformed, fields are missing,
    ///   or validation fails.
    func parse(yaml: String) throws -> Workflow {
        let dict = try loadYAMLDictionary(yaml)
        let workflow = try mapWorkflow(from: dict)

        // Fail fast on structural errors before running full validation.
        // These produce clearer, more specific error messages than the
        // generic `.validation(errors:)` wrapper.
        try detectDuplicateNodeIDs(in: workflow)
        try detectInvalidReferences(in: workflow)

        let result = validate(workflow: workflow)
        if !result.isValid {
            throw ParserError.validation(errors: result.errors)
        }
        return workflow
    }

    /// Parses a YAML workflow file from disk.
    ///
    /// - Parameter file: The absolute or relative path to a `.yaml` workflow file.
    /// - Returns: A fully populated `Workflow` value.
    /// - Throws: `ParserError` if the file cannot be read or contains invalid YAML.
    func parse(file: String) throws -> Workflow {
        let url = URL(fileURLWithPath: file)
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ParserError.yamlSyntax(detail: "Cannot read file '\(file)': \(error.localizedDescription)")
        }
        return try parse(yaml: contents)
    }

    /// Validates a parsed workflow and returns all discovered errors and warnings.
    ///
    /// This method does not throw; it collects all issues into a `ValidationResult`
    /// so callers can present every problem at once.
    func validate(workflow: Workflow) -> ValidationResult {
        var errors: [ValidationError] = []
        let warnings: [ValidationError] = []

        // 1. Required top-level fields
        if workflow.name.isEmpty {
            errors.append(ValidationError(message: "Workflow name is required"))
        }
        if workflow.nodes.isEmpty {
            errors.append(ValidationError(message: "Workflow must have at least one node"))
        }

        // Build lookup structures
        let nodeIDs = Set(workflow.nodes.map(\.id))
        let inputNames = Set(workflow.input.map(\.name))
        let outputAliases = Set(workflow.nodes.compactMap(\.output))

        // 2. Per-node validation
        for node in workflow.nodes {
            // Node must have an id
            if node.id.isEmpty {
                errors.append(ValidationError(message: "Node is missing an id", nodeID: nil))
                continue
            }

            // 3. Agent required for non-interactive, non-workflow, non-command nodes
            if node.interactive == nil && node.workflow == nil && node.command == nil && node.agent == nil {
                errors.append(ValidationError(
                    message: "Node must have an agent, command, or workflow",
                    nodeID: node.id
                ))
            }

            // 4. Interactive prompt requires message
            if case .prompt(let message) = node.interactive, message.isEmpty {
                errors.append(ValidationError(
                    message: "Interactive prompt node requires a non-empty message",
                    nodeID: node.id
                ))
            }

            // 5. depends_on references must exist
            for dep in node.dependsOn {
                if !nodeIDs.contains(dep) {
                    errors.append(ValidationError(
                        message: "depends_on references nonexistent node '\(dep)'",
                        nodeID: node.id
                    ))
                }
            }

            // 6. on_failure must be a valid value (already enforced by FailureStrategy enum,
            //    but we validated during parsing — this is a safety net)

            // 7. Template variable validation
            let templates = collectTemplateStrings(from: node)
            let knownNames = buildKnownNames(
                inputNames: inputNames,
                nodeIDs: nodeIDs,
                outputAliases: outputAliases
            )
            for template in templates {
                let unknowns = findUnknownVariables(in: template, knownNames: knownNames)
                for name in unknowns {
                    errors.append(ValidationError(
                        message: "Template variable '{{\(name)}}' references unknown name '\(name)'",
                        nodeID: node.id
                    ))
                }
            }

            // 8. Workflow nodes must have an inputs mapping
            if node.workflow != nil && (node.inputs == nil || node.inputs?.isEmpty == true) {
                errors.append(ValidationError(
                    message: "Workflow node must have an inputs mapping",
                    nodeID: node.id
                ))
            }

            // 9. when: expression syntax check
            if let whenExpr = node.when {
                if let syntaxError = checkExpressionSyntax(whenExpr) {
                    errors.append(ValidationError(
                        message: "Invalid when expression: \(syntaxError)",
                        nodeID: node.id
                    ))
                }
            }
        }

        // 9. Duplicate node IDs
        var seenIDs = Set<String>()
        for node in workflow.nodes {
            if !node.id.isEmpty {
                if seenIDs.contains(node.id) {
                    errors.append(ValidationError(
                        message: "Duplicate node id '\(node.id)'",
                        nodeID: node.id
                    ))
                }
                seenIDs.insert(node.id)
            }
        }

        // 10. Output aliases don't collide with node IDs or input names.
        // Alias collisions are errors because they cause ambiguous variable
        // resolution at runtime (a template reference could resolve to either
        // the node output or the colliding name).
        for node in workflow.nodes {
            if let alias = node.output {
                if nodeIDs.contains(alias) && alias != node.id {
                    errors.append(ValidationError(
                        message: "Output alias '\(alias)' collides with a node id",
                        nodeID: node.id
                    ))
                }
                if inputNames.contains(alias) {
                    errors.append(ValidationError(
                        message: "Output alias '\(alias)' collides with an input name",
                        nodeID: node.id
                    ))
                }
            }
        }

        // 11. DAG validation (cycle detection)
        // Only run if we have nodes and no duplicate-ID errors (duplicates break the sort).
        let hasDuplicateErrors = errors.contains { $0.message.hasPrefix("Duplicate node id") }
        if !workflow.nodes.isEmpty && !hasDuplicateErrors {
            do {
                _ = try DAGValidator.topologicalSort(nodes: workflow.nodes)
            } catch let error as ParserError {
                if case .circularDependency(let cycle) = error {
                    errors.append(ValidationError(
                        message: "Circular dependency detected: \(cycle.joined(separator: " -> "))"
                    ))
                }
            } catch {
                errors.append(ValidationError(message: "DAG validation failed: \(error)"))
            }
        }

        // 12. Validate output template variables
        if let outputMap = workflow.output {
            let knownNames = buildKnownNames(
                inputNames: inputNames,
                nodeIDs: nodeIDs,
                outputAliases: outputAliases
            )
            for (key, template) in outputMap {
                let unknowns = findUnknownVariables(in: template, knownNames: knownNames)
                for name in unknowns {
                    errors.append(ValidationError(
                        message: "Output '\(key)' references unknown variable '{{\(name)}}'"
                    ))
                }
            }
        }

        return ValidationResult(errors: errors, warnings: warnings)
    }

    // MARK: - YAML Loading

    /// Deserializes a YAML string into an untyped dictionary.
    private func loadYAMLDictionary(_ yaml: String) throws -> [String: Any] {
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: yaml)
        } catch {
            throw ParserError.yamlSyntax(detail: error.localizedDescription)
        }

        guard let dict = loaded as? [String: Any] else {
            throw ParserError.yamlSyntax(detail: "Top-level YAML must be a mapping")
        }
        return dict
    }

    // MARK: - Workflow Mapping

    /// Maps an untyped YAML dictionary to a `Workflow` value.
    private func mapWorkflow(from dict: [String: Any]) throws -> Workflow {
        // name (required)
        guard let name = dict["name"] as? String, !name.isEmpty else {
            throw ParserError.missingField(node: nil, field: "name")
        }

        // description (optional)
        let description = dict["description"] as? String

        // input (optional array of input dicts)
        let input: [WorkflowInput]
        if let inputArray = dict["input"] as? [[String: Any]] {
            input = try inputArray.map { try mapWorkflowInput(from: $0) }
        } else {
            input = []
        }

        // nodes (required)
        guard let nodesArray = dict["nodes"] as? [[String: Any]], !nodesArray.isEmpty else {
            throw ParserError.missingField(node: nil, field: "nodes")
        }
        let nodes = try nodesArray.map { try mapNode(from: $0) }

        // output (optional dict of string -> string)
        let output = dict["output"] as? [String: String]

        // cleanup (optional)
        let cleanupPolicy = mapCleanupPolicy(from: dict["cleanup"])

        return Workflow(
            name: name,
            description: description,
            input: input,
            nodes: nodes,
            output: output,
            cleanupPolicy: cleanupPolicy
        )
    }

    /// Maps an untyped dictionary to a `WorkflowInput`.
    private func mapWorkflowInput(from dict: [String: Any]) throws -> WorkflowInput {
        guard let name = dict["name"] as? String else {
            throw ParserError.missingField(node: nil, field: "input.name")
        }
        let type = dict["type"] as? String ?? "string"
        let required = dict["required"] as? Bool ?? true

        return WorkflowInput(name: name, type: type, required: required)
    }

    // MARK: - Node Mapping

    /// Maps an untyped YAML dictionary to a `Node`.
    private func mapNode(from dict: [String: Any]) throws -> Models.Node {
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw ParserError.missingField(node: nil, field: "id")
        }

        let agent = dict["agent"] as? String
        var prompt = dict["prompt"] as? String
        let command = dict["command"] as? String

        // depends_on (array of strings)
        let dependsOn: [String]
        if let deps = dict["depends_on"] as? [String] {
            dependsOn = deps
        } else if let dep = dict["depends_on"] as? String {
            dependsOn = [dep]
        } else {
            dependsOn = []
        }

        let output = dict["output"] as? String
        let when = dict["when"] as? String

        // loop (optional dict)
        let loop: LoopConfig?
        if let loopDict = dict["loop"] as? [String: Any] {
            loop = try mapLoopConfig(from: loopDict, nodeID: id)
            // If the loop block has a prompt, use that as the node's prompt
            if let loopPrompt = loopDict["prompt"] as? String, prompt == nil {
                prompt = loopPrompt
            }
        } else {
            loop = nil
        }

        // interactive (optional — "session" or "prompt")
        let interactive: InteractiveMode?
        if let interStr = dict["interactive"] as? String {
            switch interStr {
            case "session":
                interactive = .session
            case "prompt":
                let message = dict["message"] as? String ?? ""
                interactive = .prompt(message: message)
            default:
                throw ParserError.invalidExpression(
                    node: id,
                    detail: "Invalid interactive mode '\(interStr)'; expected 'session' or 'prompt'"
                )
            }
        } else {
            interactive = nil
        }

        // retry (optional dict)
        let retry: RetryConfig?
        if let retryDict = dict["retry"] as? [String: Any] {
            retry = mapRetryConfig(from: retryDict)
        } else {
            retry = nil
        }

        // timeout_seconds (optional)
        let timeoutSeconds = dict["timeout_seconds"] as? Int

        // on_failure (optional, defaults to "stop")
        let onFailure: FailureStrategy
        if let failStr = dict["on_failure"] as? String {
            guard let strategy = FailureStrategy(rawValue: failStr) else {
                throw ParserError.invalidExpression(
                    node: id,
                    detail: "Invalid on_failure value '\(failStr)'; expected 'stop', 'skip', or 'continue'"
                )
            }
            onFailure = strategy
        } else {
            onFailure = .stop
        }

        // workflow (optional — nested workflow path)
        let workflow = dict["workflow"] as? String

        // inputs (optional dict for nested workflows)
        let inputs = dict["inputs"] as? [String: String]

        // workspace (optional — "shared" or "isolated")
        let workspaceMode: WorkspaceMode?
        if let wsStr = dict["workspace"] as? String {
            guard let mode = WorkspaceMode(rawValue: wsStr) else {
                throw ParserError.invalidExpression(
                    node: id,
                    detail: "Invalid workspace mode '\(wsStr)'; expected 'shared' or 'isolated'"
                )
            }
            workspaceMode = mode
        } else {
            workspaceMode = nil
        }

        return Node(
            id: id,
            agent: agent,
            prompt: prompt,
            command: command,
            dependsOn: dependsOn,
            output: output,
            when: when,
            loop: loop,
            interactive: interactive,
            retry: retry,
            timeoutSeconds: timeoutSeconds,
            onFailure: onFailure,
            workflow: workflow,
            inputs: inputs,
            workspaceMode: workspaceMode
        )
    }

    /// Maps a loop dictionary to `LoopConfig`.
    private func mapLoopConfig(from dict: [String: Any], nodeID: String) throws -> LoopConfig {
        guard let until = dict["until"] as? String else {
            throw ParserError.missingField(node: nodeID, field: "loop.until")
        }
        let maxIterations = dict["max_iterations"] as? Int ?? 10
        let freshContext = dict["fresh_context"] as? Bool ?? false

        return LoopConfig(
            until: until,
            maxIterations: maxIterations,
            freshContext: freshContext
        )
    }

    /// Maps a retry dictionary to `RetryConfig`.
    private func mapRetryConfig(from dict: [String: Any]) -> RetryConfig {
        let maxAttempts = dict["max_attempts"] as? Int ?? 1
        let delaySeconds = dict["delay_seconds"] as? Int ?? 0
        return RetryConfig(maxAttempts: maxAttempts, delaySeconds: delaySeconds)
    }

    /// Maps a cleanup value to `CleanupPolicy`.
    private func mapCleanupPolicy(from value: Any?) -> CleanupPolicy {
        guard let str = value as? String else {
            return .duration(days: 30)
        }
        switch str {
        case "on_success":
            return .onSuccess
        case "always":
            return .always
        case "never":
            return .never
        default:
            // Parse duration format: "30d" -> .duration(days: 30)
            if str.hasSuffix("d"), let days = Int(str.dropLast()) {
                return .duration(days: days)
            }
            return .duration(days: 30)
        }
    }

    // MARK: - Template Variable Validation

    /// Collects all template-bearing strings from a node (prompt, when, command, input map values).
    private func collectTemplateStrings(from node: Models.Node) -> [String] {
        var templates: [String] = []
        if let prompt = node.prompt { templates.append(prompt) }
        if let when = node.when { templates.append(when) }
        if let command = node.command { templates.append(command) }
        if let inputs = node.inputs {
            templates.append(contentsOf: inputs.values)
        }
        return templates
    }

    /// Builds the set of names that are valid targets for `{{variable}}` references.
    ///
    /// Includes: input names, node IDs (with `.output` and `.status` suffixes),
    /// output aliases, and built-in names like `workspace` and `last_output`.
    private func buildKnownNames(
        inputNames: Set<String>,
        nodeIDs: Set<String>,
        outputAliases: Set<String>
    ) -> Set<String> {
        var known = Set<String>()

        // Input names are directly referenceable
        known.formUnion(inputNames)

        // Node IDs can be referenced as {{id.output}} or {{id.status}}
        for id in nodeIDs {
            known.insert(id)
            known.insert("\(id).output")
            known.insert("\(id).status")
        }

        // Output aliases are directly referenceable
        known.formUnion(outputAliases)

        // Built-in variables
        known.insert("workspace")
        known.insert("last_output")

        return known
    }

    /// Extracts `{{variable}}` references from a template and returns any
    /// that are not in the known names set.
    private func findUnknownVariables(in template: String, knownNames: Set<String>) -> [String] {
        var unknowns: [String] = []
        let chars = Array(template.unicodeScalars)
        let count = chars.count
        var i = 0

        while i < count {
            // Skip escaped braces
            if chars[i] == "\\" && i + 2 < count && chars[i + 1] == "{" && chars[i + 2] == "{" {
                i += 3
                continue
            }

            // Found opening {{
            if chars[i] == "{" && i + 1 < count && chars[i + 1] == "{" {
                i += 2
                // Find closing }}
                var varName = ""
                while i + 1 < count {
                    if chars[i] == "}" && chars[i + 1] == "}" {
                        i += 2
                        break
                    }
                    varName.append(String(chars[i]))
                    i += 1
                }

                let trimmed = varName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !knownNames.contains(trimmed) {
                    unknowns.append(trimmed)
                }
                continue
            }

            i += 1
        }

        return unknowns
    }

    // MARK: - Expression Syntax Check

    /// Performs a lightweight syntax check on a `when:` expression.
    ///
    /// Returns a description of the syntax error if one is found, or nil if
    /// the expression appears syntactically valid.
    ///
    /// This does not evaluate the expression or resolve variables — it only
    /// checks for balanced parentheses, valid operators, and well-formed tokens.
    private func checkExpressionSyntax(_ expression: String) -> String? {
        // Check for balanced parentheses
        var depth = 0
        for ch in expression {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if depth < 0 { return "Unmatched ')'" }
        }
        if depth != 0 { return "Unmatched '('" }

        // Check for unterminated string literals
        var inString = false
        let chars = Array(expression)
        var i = 0
        while i < chars.count {
            if chars[i] == "'" {
                if inString {
                    inString = false
                } else {
                    inString = true
                }
            } else if chars[i] == "\\" && inString && i + 1 < chars.count && chars[i + 1] == "'" {
                // Escaped quote inside string
                i += 1
            }
            i += 1
        }
        if inString { return "Unterminated string literal" }

        // Check for dangling operators at end (e.g., "foo ==")
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("==") || trimmed.hasSuffix("!=")
            || trimmed.hasSuffix("&&") || trimmed.hasSuffix("||")
        {
            return "Expression ends with an operator"
        }

        // Check for leading binary operators (e.g., "== foo")
        if trimmed.hasPrefix("==") || trimmed.hasPrefix("!=")
            || trimmed.hasPrefix("&&") || trimmed.hasPrefix("||")
        {
            return "Expression starts with a binary operator"
        }

        return nil
    }

    // MARK: - Fast Structural Checks

    /// Throws `.duplicateNodeID` on the first duplicate found.
    ///
    /// This runs before full validation so callers get a specific, actionable
    /// error rather than a generic `validation(errors:)` wrapper.
    private func detectDuplicateNodeIDs(in workflow: Workflow) throws {
        var seen = Set<String>()
        for node in workflow.nodes where !node.id.isEmpty {
            if seen.contains(node.id) {
                throw ParserError.duplicateNodeID(id: node.id)
            }
            seen.insert(node.id)
        }
    }

    /// Throws `.invalidReference` on the first dangling `depends_on` reference.
    ///
    /// Catches references to nonexistent nodes early with a targeted error
    /// that names both the referencing node and the missing dependency.
    private func detectInvalidReferences(in workflow: Workflow) throws {
        let nodeIDs = Set(workflow.nodes.map(\.id))
        for node in workflow.nodes {
            for dep in node.dependsOn {
                if !nodeIDs.contains(dep) {
                    throw ParserError.invalidReference(node: node.id, ref: dep)
                }
            }
        }
    }
}

// MARK: - Factory

/// Factory for creating `WorkflowParsing` instances.
///
/// The concrete `WorkflowParser` type is `internal`; callers across module
/// boundaries access it through this factory and the `WorkflowParsing` protocol.
public enum ParserFactory {
    public static func makeParser() -> any WorkflowParsing {
        WorkflowParser()
    }
}
