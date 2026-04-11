import Foundation
import Models
import Providers
import Template
import Yams

/// Resolves evaluators by name and runs them to produce a boolean outcome.
///
/// Built-in evaluators:
/// - `approved`: returns true if lastOutput matches "yes", "y", "approve", "approved" (case-insensitive)
/// - `output_unchanged`: compares current output to previous iteration output (via context)
///
/// Custom evaluators are loaded from `.orc/evaluators/<name>.yml`.
/// Resolution order: built-in evaluators first, then custom YAML definitions.
struct EvaluatorRunner: EvaluatorProviding, Sendable {
    let providers: ProviderRegistry
    let store: any WorkflowStoring
    let templateResolver: any TemplateResolving
    let processRunner: any ProcessRunning
    /// Path to the `.orc/` directory. Custom evaluators live under `<basePath>/evaluators/`.
    let basePath: String
    /// Path to the orc binary for running child workflows. Defaults to the
    /// current process executable, falling back to `/usr/local/bin/orc`.
    let orcBinaryPath: String

    init(
        providers: ProviderRegistry,
        store: any WorkflowStoring,
        templateResolver: any TemplateResolving,
        processRunner: any ProcessRunning,
        basePath: String,
        orcBinaryPath: String = "/usr/local/bin/orc"
    ) {
        self.providers = providers
        self.store = store
        self.templateResolver = templateResolver
        self.processRunner = processRunner
        self.basePath = basePath
        self.orcBinaryPath = orcBinaryPath
    }

    /// Evaluates the named evaluator against the last output and current context.
    ///
    /// Resolution order:
    /// 1. Built-in evaluators (approved, output_unchanged)
    /// 2. Custom evaluators from `.orc/evaluators/<name>.yml`
    ///
    /// - Parameters:
    ///   - name: The evaluator name (e.g., "approved", "output_unchanged", or a custom name).
    ///   - lastOutput: The output from the most recent iteration.
    ///   - context: The current task context with accumulated inputs/outputs.
    /// - Returns: `true` if the evaluator condition is met.
    /// - Throws: `EngineError.evaluatorNotFound` or `EngineError.evaluatorFailed`.
    func evaluate(name: String, lastOutput: String, context: TaskContext) async throws -> Bool {
        // Built-in evaluators take precedence.
        switch name {
        case "approved":
            return evaluateApproved(lastOutput: lastOutput)
        case "output_unchanged":
            return evaluateOutputUnchanged(lastOutput: lastOutput, context: context)
        default:
            // Attempt to load a custom evaluator from .orc/evaluators/<name>.yml
            return try await evaluateCustom(name: name, lastOutput: lastOutput, context: context)
        }
    }

    // MARK: - Built-in Evaluators

    /// Returns true if the output matches common approval words (case-insensitive).
    private func evaluateApproved(lastOutput: String) -> Bool {
        let normalized = lastOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let approvalWords: Set<String> = ["yes", "y", "approve", "approved"]
        return approvalWords.contains(normalized)
    }

    /// Returns true if the current output matches the previous iteration's output.
    /// On the first iteration (no previous output in context), returns false.
    private func evaluateOutputUnchanged(lastOutput: String, context: TaskContext) -> Bool {
        guard let previousOutput = context.outputs["_previous_iteration_output"] else {
            // First iteration — no previous output to compare against.
            return false
        }
        return lastOutput == previousOutput
    }

    // MARK: - Custom Evaluators

    /// Loads and executes a custom evaluator from `.orc/evaluators/<name>.yml`.
    ///
    /// The YAML file is parsed into an `EvaluatorDefinition` and dispatched
    /// based on its `type` field (ai, script, or workflow).
    private func evaluateCustom(
        name: String,
        lastOutput: String,
        context: TaskContext
    ) async throws -> Bool {
        let definition = try loadEvaluatorDefinition(name: name)

        switch definition.type {
        case .ai:
            return try await evaluateAI(definition: definition, lastOutput: lastOutput, context: context)
        case .script:
            return try await evaluateScript(definition: definition, lastOutput: lastOutput, context: context)
        case .workflow:
            return try await evaluateWorkflow(definition: definition, lastOutput: lastOutput, context: context)
        }
    }

    /// Loads and parses an evaluator YAML file from `.orc/evaluators/<name>.yml`.
    ///
    /// - Parameter name: The evaluator name, used to derive the file path.
    /// - Returns: The parsed `EvaluatorDefinition`.
    /// - Throws: `EngineError.evaluatorNotFound` if the file does not exist,
    ///   or `EngineError.evaluatorFailed` if the YAML is malformed.
    func loadEvaluatorDefinition(name: String) throws -> EvaluatorDefinition {
        let evaluatorsDir = (basePath as NSString).appendingPathComponent("evaluators")
        let filePath = (evaluatorsDir as NSString).appendingPathComponent("\(name).yml")

        guard FileManager.default.fileExists(atPath: filePath) else {
            throw EngineError.evaluatorNotFound(name: name)
        }

        let yamlString: String
        do {
            yamlString = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            throw EngineError.evaluatorFailed(
                name: name,
                detail: "Failed to read evaluator file at \(filePath): \(error.localizedDescription)"
            )
        }

        return try parseEvaluatorYAML(yamlString, name: name)
    }

    /// Parses a YAML string into an `EvaluatorDefinition`.
    ///
    /// Expected YAML format for AI evaluators:
    /// ```yaml
    /// name: all_tasks_complete
    /// type: ai
    /// agent: claude-code
    /// prompt: "Given this output:\n{{last_output}}\n\nAre all tasks complete?"
    /// ```
    ///
    /// Expected YAML format for script evaluators:
    /// ```yaml
    /// name: tests_pass
    /// type: script
    /// command: "cd {{workspace}} && swift test"
    /// ```
    func parseEvaluatorYAML(_ yamlString: String, name: String) throws -> EvaluatorDefinition {
        let parsed: [String: Any]
        do {
            guard let dict = try Yams.load(yaml: yamlString) as? [String: Any] else {
                throw EngineError.evaluatorFailed(
                    name: name,
                    detail: "Evaluator YAML must be a dictionary at the top level."
                )
            }
            parsed = dict
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.evaluatorFailed(
                name: name,
                detail: "Failed to parse evaluator YAML: \(error.localizedDescription)"
            )
        }

        guard let typeString = parsed["type"] as? String else {
            throw EngineError.evaluatorFailed(
                name: name,
                detail: "Evaluator YAML missing required 'type' field."
            )
        }

        guard let evaluatorType = EvaluatorType(rawValue: typeString) else {
            throw EngineError.evaluatorFailed(
                name: name,
                detail: "Unknown evaluator type '\(typeString)'. Valid types: ai, script, workflow."
            )
        }

        let evaluatorName = parsed["name"] as? String ?? name
        let agent = parsed["agent"] as? String
        let prompt = parsed["prompt"] as? String
        let command = parsed["command"] as? String

        return EvaluatorDefinition(
            name: evaluatorName,
            type: evaluatorType,
            agent: agent,
            prompt: prompt,
            command: command
        )
    }

    // MARK: - AI Evaluator Execution

    /// Executes an AI-type evaluator by resolving the prompt template and calling the named agent.
    ///
    /// Template variables like `{{last_output}}` are resolved before sending
    /// the prompt to the agent. The agent's response is parsed for truthy values:
    /// "yes", "true", "y" (case-insensitive, trimmed) return true; everything else returns false.
    private func evaluateAI(
        definition: EvaluatorDefinition,
        lastOutput: String,
        context: TaskContext
    ) async throws -> Bool {
        guard let promptTemplate = definition.prompt else {
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "AI evaluator requires a 'prompt' field."
            )
        }

        guard let agentName = definition.agent else {
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "AI evaluator requires an 'agent' field."
            )
        }

        // Build a context that includes last_output for template resolution.
        var resolvedOutputs = context.outputs
        resolvedOutputs["last_output"] = lastOutput
        let resolvedContext = TaskContext(
            inputs: context.inputs,
            outputs: resolvedOutputs,
            nodeStatuses: context.nodeStatuses,
            repoRoot: context.repoRoot,

            workspacePath: context.workspacePath
        )

        // Resolve {{last_output}} and any other template variables in the prompt.
        let resolvedPrompt = try templateResolver.resolve(
            template: promptTemplate,
            context: resolvedContext
        )

        // Execute via the named agent provider.
        let provider: any AgentProviding
        do {
            provider = try providers.provider(named: agentName)
        } catch {
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "Agent '\(agentName)' not found in provider registry."
            )
        }

        let output: TaskOutput
        do {
            output = try await provider.execute(prompt: resolvedPrompt, context: resolvedContext, timeout: nil)
        } catch {
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "Agent execution failed: \(error.localizedDescription)"
            )
        }

        // Parse the response: truthy if it contains "yes", "true", or "y" (case-insensitive, trimmed).
        return parseTruthyResponse(output.output)
    }

    /// Parses an agent response for truthy values.
    /// Returns true if the trimmed, lowercased response is "yes", "true", or "y".
    func parseTruthyResponse(_ response: String) -> Bool {
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let truthyValues: Set<String> = ["yes", "true", "y"]
        return truthyValues.contains(normalized)
    }

    // MARK: - Script Evaluator Execution

    /// Executes a script-type evaluator by running the command via ProcessRunning.
    ///
    /// Template variables like `{{last_output}}` and `{{workspace}}` are resolved
    /// in the command string. The last output is also passed via the `ORC_LAST_OUTPUT`
    /// environment variable. Exit code 0 means true; any other exit code means false.
    private func evaluateScript(
        definition: EvaluatorDefinition,
        lastOutput: String,
        context: TaskContext
    ) async throws -> Bool {
        guard let commandTemplate = definition.command else {
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "Script evaluator requires a 'command' field."
            )
        }

        // Build a context that includes last_output and workspace for template resolution.
        var resolvedOutputs = context.outputs
        resolvedOutputs["last_output"] = lastOutput
        resolvedOutputs["workspace"] = context.workspacePath
        let resolvedContext = TaskContext(
            inputs: context.inputs,
            outputs: resolvedOutputs,
            nodeStatuses: context.nodeStatuses,
            repoRoot: context.repoRoot,

            workspacePath: context.workspacePath
        )

        // Resolve template variables in the command.
        let resolvedCommand = try templateResolver.resolve(
            template: commandTemplate,
            context: resolvedContext
        )

        // Set up environment with ORC_LAST_OUTPUT.
        let environment = ["ORC_LAST_OUTPUT": lastOutput]

        // Run the command. Exit code 0 = true, anything else = false.
        let result = try await processRunner.run(
            command: resolvedCommand,
            arguments: [],
            workingDirectory: context.repoRoot,
            environment: environment,
            timeout: nil,
            stdoutPath: nil,
            stderrPath: nil
        )

        return result.exitCode == 0
    }

    // MARK: - Workflow Evaluator Execution

    /// Executes a workflow-type evaluator by running a child workflow via the Orc CLI
    /// as a subprocess.
    ///
    /// Per the spec, the last output is passed as an input to the child workflow
    /// via `--input last_output=<value>`. The child workflow's final output is read
    /// from stdout and parsed for truthy values ("yes", "true", "y").
    ///
    /// If the child workflow process exits with a non-zero code, the evaluator is
    /// treated as failed (not as "false"), which causes the parent node to fail.
    /// This prevents infinite loops from broken evaluator workflows.
    private func evaluateWorkflow(
        definition: EvaluatorDefinition,
        lastOutput: String,
        context: TaskContext
    ) async throws -> Bool {
        guard let workflowPath = definition.command else {
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "Workflow evaluator requires a 'command' field specifying the workflow file path."
            )
        }

        // Resolve template variables (e.g., {{workspace}}) in the workflow path.
        var resolvedOutputs = context.outputs
        resolvedOutputs["last_output"] = lastOutput
        resolvedOutputs["workspace"] = context.workspacePath
        let resolvedContext = TaskContext(
            inputs: context.inputs,
            outputs: resolvedOutputs,
            nodeStatuses: context.nodeStatuses,
            repoRoot: context.repoRoot,

            workspacePath: context.workspacePath
        )

        let resolvedPath = try templateResolver.resolve(
            template: workflowPath,
            context: resolvedContext
        )

        // Create a temp file to capture the child workflow's stdout.
        let stdoutFile = NSTemporaryDirectory() + "orc-eval-\(definition.name)-\(UUID().uuidString).out"
        defer { try? FileManager.default.removeItem(atPath: stdoutFile) }

        // Run the child workflow via the Orc CLI using direct execution to avoid
        // shell-string injection. Arguments are passed as discrete argv elements.
        let stderrFile = NSTemporaryDirectory() + "orc-eval-\(definition.name)-\(UUID().uuidString).err"
        defer { try? FileManager.default.removeItem(atPath: stderrFile) }

        let result = try await processRunner.run(
            command: "orc",
            arguments: ["start", resolvedPath, "--input", "last_output=\(lastOutput)"],
            workingDirectory: context.repoRoot,
            environment: nil,
            timeout: nil,
            stdoutPath: stdoutFile,
            stderrPath: stderrFile,
            executablePath: orcBinaryPath
        )

        // Non-zero exit = evaluator failure (not "false"). Per spec, evaluator
        // failures are treated as node failures to prevent infinite loops.
        guard result.exitCode == 0 else {
            let stderr = (try? String(contentsOfFile: stderrFile, encoding: .utf8)) ?? ""
            throw EngineError.evaluatorFailed(
                name: definition.name,
                detail: "Child workflow '\(resolvedPath)' exited with code \(result.exitCode). \(stderr)"
            )
        }

        // Read the child workflow's stdout and parse the final output for truthy values.
        let output = (try? String(contentsOfFile: stdoutFile, encoding: .utf8)) ?? ""
        return parseTruthyResponse(output)
    }

}
