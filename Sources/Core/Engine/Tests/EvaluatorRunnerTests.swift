import Foundation
import Testing
import Models
import Providers
@testable import Engine

/// Tests for the built-in evaluators: approved and output_unchanged.
struct EvaluatorRunnerTests {

    private func makeRunner(
        providers: ProviderRegistry? = nil,
        templateResolver: (any TemplateResolving)? = nil,
        processRunner: (any ProcessRunning)? = nil,
        basePath: String = "/tmp/test-orc"
    ) -> EvaluatorRunner {
        let fakeProvider = FakeAgentProvider(name: "fake")
        let registry = providers ?? ProviderRegistry(providers: [fakeProvider])
        let store = FakeWorkflowStore()
        let resolver = templateResolver ?? FakeTemplateResolver()
        let runner = processRunner ?? FakeProcessRunner()

        return EvaluatorRunner(
            providers: registry,
            store: store,
            templateResolver: resolver,
            processRunner: runner,
            basePath: basePath
        )
    }

    private func makeContext() -> TaskContext {
        TaskContext(workspacePath: "/tmp/test")
    }

    // MARK: - Approved Evaluator

    @Test("approved evaluator returns true for 'yes'")
    func approvedYes() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "yes", context: makeContext())
        #expect(result == true)
    }

    @Test("approved evaluator returns true for 'y'")
    func approvedY() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "y", context: makeContext())
        #expect(result == true)
    }

    @Test("approved evaluator returns true for 'approve'")
    func approvedApprove() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "approve", context: makeContext())
        #expect(result == true)
    }

    @Test("approved evaluator returns true for 'Approved' (case-insensitive)")
    func approvedCaseInsensitive() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "Approved", context: makeContext())
        #expect(result == true)
    }

    @Test("approved evaluator returns true for 'YES' (case-insensitive)")
    func approvedYesCaseInsensitive() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "YES", context: makeContext())
        #expect(result == true)
    }

    @Test("approved evaluator returns false for 'no'")
    func approvedNo() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "no", context: makeContext())
        #expect(result == false)
    }

    @Test("approved evaluator returns false for arbitrary text")
    func approvedArbitraryText() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "maybe", context: makeContext())
        #expect(result == false)
    }

    @Test("approved evaluator handles whitespace-padded input")
    func approvedWithWhitespace() async throws {
        let runner = makeRunner()
        let result = try await runner.evaluate(name: "approved", lastOutput: "  yes  \n", context: makeContext())
        #expect(result == true)
    }

    // MARK: - Output Unchanged Evaluator

    @Test("output_unchanged returns false on first iteration (no previous output)")
    func outputUnchangedFirstIteration() async throws {
        let runner = makeRunner()
        let context = TaskContext(workspacePath: "/tmp/test")
        let result = try await runner.evaluate(name: "output_unchanged", lastOutput: "hello", context: context)
        #expect(result == false)
    }

    @Test("output_unchanged returns true when output matches previous")
    func outputUnchangedMatches() async throws {
        let runner = makeRunner()
        let context = TaskContext(
            outputs: ["_previous_iteration_output": "hello"],
            workspacePath: "/tmp/test"
        )
        let result = try await runner.evaluate(name: "output_unchanged", lastOutput: "hello", context: context)
        #expect(result == true)
    }

    @Test("output_unchanged returns false when output differs from previous")
    func outputUnchangedDiffers() async throws {
        let runner = makeRunner()
        let context = TaskContext(
            outputs: ["_previous_iteration_output": "hello"],
            workspacePath: "/tmp/test"
        )
        let result = try await runner.evaluate(name: "output_unchanged", lastOutput: "world", context: context)
        #expect(result == false)
    }

    // MARK: - Unknown Evaluator (no built-in, no file)

    @Test("Unknown evaluator with no YAML file throws evaluatorNotFound")
    func unknownEvaluator() async throws {
        let runner = makeRunner()
        await #expect(throws: EngineError.self) {
            try await runner.evaluate(name: "nonexistent", lastOutput: "x", context: makeContext())
        }
    }

    // MARK: - YAML Parsing

    @Test("parseEvaluatorYAML parses AI evaluator correctly")
    func parseAIEvaluator() throws {
        let yaml = """
        name: all_tasks_complete
        type: ai
        agent: claude-code
        prompt: "Given this output:\\n{{last_output}}\\n\\nAre all tasks complete?"
        """
        let runner = makeRunner()
        let definition = try runner.parseEvaluatorYAML(yaml, name: "all_tasks_complete")

        #expect(definition.name == "all_tasks_complete")
        #expect(definition.type == .ai)
        #expect(definition.agent == "claude-code")
        #expect(definition.prompt != nil)
        #expect(definition.command == nil)
    }

    @Test("parseEvaluatorYAML parses script evaluator correctly")
    func parseScriptEvaluator() throws {
        let yaml = """
        name: tests_pass
        type: script
        command: "cd {{workspace}} && swift test"
        """
        let runner = makeRunner()
        let definition = try runner.parseEvaluatorYAML(yaml, name: "tests_pass")

        #expect(definition.name == "tests_pass")
        #expect(definition.type == .script)
        #expect(definition.command == "cd {{workspace}} && swift test")
        #expect(definition.agent == nil)
        #expect(definition.prompt == nil)
    }

    @Test("parseEvaluatorYAML parses workflow evaluator correctly")
    func parseWorkflowEvaluator() throws {
        let yaml = """
        name: check_workflow
        type: workflow
        command: "workflows/validation.yml"
        """
        let runner = makeRunner()
        let definition = try runner.parseEvaluatorYAML(yaml, name: "check_workflow")

        #expect(definition.name == "check_workflow")
        #expect(definition.type == .workflow)
        #expect(definition.command == "workflows/validation.yml")
        #expect(definition.agent == nil)
        #expect(definition.prompt == nil)
    }

    @Test("parseEvaluatorYAML uses file name when YAML omits name field")
    func parseEvaluatorUsesFileName() throws {
        let yaml = """
        type: script
        command: "echo test"
        """
        let runner = makeRunner()
        let definition = try runner.parseEvaluatorYAML(yaml, name: "my_evaluator")

        #expect(definition.name == "my_evaluator")
    }

    @Test("parseEvaluatorYAML throws for missing type field")
    func parseMissingType() throws {
        let yaml = """
        name: bad_evaluator
        command: "echo test"
        """
        let runner = makeRunner()
        #expect(throws: EngineError.self) {
            try runner.parseEvaluatorYAML(yaml, name: "bad_evaluator")
        }
    }

    @Test("parseEvaluatorYAML throws for unknown type")
    func parseUnknownType() throws {
        let yaml = """
        name: bad_evaluator
        type: quantum
        """
        let runner = makeRunner()
        #expect(throws: EngineError.self) {
            try runner.parseEvaluatorYAML(yaml, name: "bad_evaluator")
        }
    }

    @Test("parseEvaluatorYAML throws for invalid YAML")
    func parseInvalidYAML() throws {
        let yaml = "{{{{not valid yaml"
        let runner = makeRunner()
        #expect(throws: EngineError.self) {
            try runner.parseEvaluatorYAML(yaml, name: "bad_evaluator")
        }
    }

    // MARK: - AI Evaluator Response Parsing

    @Test("parseTruthyResponse returns true for 'yes'")
    func truthyYes() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("yes") == true)
    }

    @Test("parseTruthyResponse returns true for 'YES'")
    func truthyYESUppercase() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("YES") == true)
    }

    @Test("parseTruthyResponse returns true for 'true'")
    func truthyTrue() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("true") == true)
    }

    @Test("parseTruthyResponse returns true for 'y'")
    func truthyY() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("y") == true)
    }

    @Test("parseTruthyResponse returns true for padded 'Yes\\n'")
    func truthyPadded() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("  Yes\n") == true)
    }

    @Test("parseTruthyResponse returns false for 'no'")
    func truthyNo() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("no") == false)
    }

    @Test("parseTruthyResponse returns false for 'false'")
    func truthyFalse() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("false") == false)
    }

    @Test("parseTruthyResponse returns false for arbitrary text")
    func truthyArbitrary() {
        let runner = makeRunner()
        #expect(runner.parseTruthyResponse("All tasks are complete") == false)
    }

    // MARK: - AI Evaluator End-to-End

    @Test("AI evaluator resolves template and returns true for 'YES' response")
    func aiEvaluatorReturnsTrue() async throws {
        // Set up a temp directory with an evaluator YAML file.
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: check_complete
        type: ai
        agent: fake
        prompt: "Is this done? {{last_output}}"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("check_complete.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        // The fake provider returns "YES" for any prompt.
        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "YES"
        let registry = ProviderRegistry(providers: [fakeProvider])

        // Use a template resolver that actually substitutes {{last_output}}.
        let resolver = SubstitutingTemplateResolver()

        let runner = makeRunner(
            providers: registry,
            templateResolver: resolver,
            basePath: tempDir
        )

        let result = try await runner.evaluate(
            name: "check_complete",
            lastOutput: "Build succeeded",
            context: makeContext()
        )

        #expect(result == true)
        // Verify the prompt was resolved with the last output.
        #expect(fakeProvider.executedPrompts.count == 1)
        #expect(fakeProvider.executedPrompts[0].contains("Build succeeded"))
    }

    @Test("AI evaluator returns false for 'NO' response")
    func aiEvaluatorReturnsFalse() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: check_complete
        type: ai
        agent: fake
        prompt: "Is this done? {{last_output}}"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("check_complete.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProvider = FakeAgentProvider(name: "fake")
        fakeProvider.defaultOutput = "NO"
        let registry = ProviderRegistry(providers: [fakeProvider])
        let resolver = SubstitutingTemplateResolver()

        let runner = makeRunner(
            providers: registry,
            templateResolver: resolver,
            basePath: tempDir
        )

        let result = try await runner.evaluate(
            name: "check_complete",
            lastOutput: "Still working",
            context: makeContext()
        )

        #expect(result == false)
    }

    @Test("AI evaluator throws when agent is missing from registry")
    func aiEvaluatorMissingAgent() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: check_complete
        type: ai
        agent: nonexistent-agent
        prompt: "Is this done?"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("check_complete.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        // Registry has no provider named "nonexistent-agent".
        let runner = makeRunner(basePath: tempDir)

        await #expect(throws: EngineError.self) {
            try await runner.evaluate(
                name: "check_complete",
                lastOutput: "test",
                context: makeContext()
            )
        }
    }

    // MARK: - Script Evaluator End-to-End

    @Test("Script evaluator returns true for exit code 0")
    func scriptEvaluatorExitZero() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: tests_pass
        type: script
        command: "swift test"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("tests_pass.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(exitCode: 0)
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        let result = try await runner.evaluate(
            name: "tests_pass",
            lastOutput: "some output",
            context: makeContext()
        )

        #expect(result == true)
        #expect(fakeProcess.executedCommands.count == 1)
        #expect(fakeProcess.executedCommands[0] == "swift test")
    }

    @Test("Script evaluator returns false for non-zero exit code")
    func scriptEvaluatorExitNonZero() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: tests_pass
        type: script
        command: "swift test"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("tests_pass.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(exitCode: 1)
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        let result = try await runner.evaluate(
            name: "tests_pass",
            lastOutput: "some output",
            context: makeContext()
        )

        #expect(result == false)
    }

    @Test("Script evaluator passes ORC_LAST_OUTPUT environment variable")
    func scriptEvaluatorPassesEnvVar() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: check_env
        type: script
        command: "echo check"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("check_env.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(exitCode: 0)
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        _ = try await runner.evaluate(
            name: "check_env",
            lastOutput: "my special output",
            context: makeContext()
        )

        #expect(fakeProcess.executedEnvironments.count == 1)
        #expect(fakeProcess.executedEnvironments[0]?["ORC_LAST_OUTPUT"] == "my special output")
    }

    @Test("Script evaluator resolves template variables in command")
    func scriptEvaluatorResolvesTemplates() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: check_workspace
        type: script
        command: "cd {{workspace}} && swift test"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("check_workspace.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(exitCode: 0)
        let resolver = SubstitutingTemplateResolver()
        let runner = makeRunner(
            templateResolver: resolver,
            processRunner: fakeProcess,
            basePath: tempDir
        )

        _ = try await runner.evaluate(
            name: "check_workspace",
            lastOutput: "output",
            context: makeContext()
        )

        #expect(fakeProcess.executedCommands.count == 1)
        // The SubstitutingTemplateResolver replaces {{workspace}} with the workspace path.
        #expect(fakeProcess.executedCommands[0].contains("/tmp/test"))
    }

    // MARK: - Workflow Evaluator

    @Test("Workflow evaluator returns true when child workflow outputs 'true'")
    func workflowEvaluatorReturnsTrue() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: nested_workflow
        type: workflow
        command: "check.yml"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("nested_workflow.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        // Fake process runner that writes "true" to the stdout file and exits 0.
        let fakeProcess = FakeProcessRunner(handler: { command, _, _, stdoutPath, stderrPath in
            if let stdoutPath, stdoutPath != "/dev/null" {
                try? "true".write(toFile: stdoutPath, atomically: true, encoding: .utf8)
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        })
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        let result = try await runner.evaluate(
            name: "nested_workflow",
            lastOutput: "some output",
            context: makeContext()
        )

        #expect(result == true)
        #expect(fakeProcess.executedCommands.count == 1)
        #expect(fakeProcess.executedCommands[0].contains("orc start"))
        #expect(fakeProcess.executedCommands[0].contains("check.yml"))
    }

    @Test("Workflow evaluator returns false when child workflow outputs 'false'")
    func workflowEvaluatorReturnsFalse() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: nested_workflow
        type: workflow
        command: "check.yml"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("nested_workflow.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(handler: { command, _, _, stdoutPath, stderrPath in
            if let stdoutPath, stdoutPath != "/dev/null" {
                try? "no".write(toFile: stdoutPath, atomically: true, encoding: .utf8)
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        })
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        let result = try await runner.evaluate(
            name: "nested_workflow",
            lastOutput: "some output",
            context: makeContext()
        )

        #expect(result == false)
    }

    @Test("Workflow evaluator passes last_output as input to child workflow")
    func workflowEvaluatorPassesLastOutput() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: nested_workflow
        type: workflow
        command: "check.yml"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("nested_workflow.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(handler: { command, _, _, stdoutPath, stderrPath in
            if let stdoutPath, stdoutPath != "/dev/null" {
                try? "yes".write(toFile: stdoutPath, atomically: true, encoding: .utf8)
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        })
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        _ = try await runner.evaluate(
            name: "nested_workflow",
            lastOutput: "build succeeded",
            context: makeContext()
        )

        // Verify the command includes --input last_output= with the value.
        #expect(fakeProcess.executedCommands.count == 1)
        #expect(fakeProcess.executedCommands[0].contains("--input last_output="))
        #expect(fakeProcess.executedCommands[0].contains("build succeeded"))
    }

    @Test("Workflow evaluator throws evaluatorFailed when child process exits non-zero")
    func workflowEvaluatorFailsOnNonZeroExit() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: nested_workflow
        type: workflow
        command: "broken.yml"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("nested_workflow.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(exitCode: 1)
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        await #expect(throws: EngineError.self) {
            try await runner.evaluate(
                name: "nested_workflow",
                lastOutput: "test",
                context: makeContext()
            )
        }
    }

    @Test("Workflow evaluator throws evaluatorFailed when command field is missing")
    func workflowEvaluatorMissingCommand() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: nested_workflow
        type: workflow
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("nested_workflow.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let runner = makeRunner(basePath: tempDir)

        await #expect(throws: EngineError.self) {
            try await runner.evaluate(
                name: "nested_workflow",
                lastOutput: "test",
                context: makeContext()
            )
        }
    }

    @Test("Workflow evaluator resolves template variables in workflow path")
    func workflowEvaluatorResolvesTemplates() async throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: nested_workflow
        type: workflow
        command: "{{workspace}}/workflows/check.yml"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("nested_workflow.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(handler: { command, _, _, stdoutPath, stderrPath in
            if let stdoutPath, stdoutPath != "/dev/null" {
                try? "yes".write(toFile: stdoutPath, atomically: true, encoding: .utf8)
            }
            return ProcessResult(
                exitCode: 0,
                stdoutPath: stdoutPath ?? "/dev/null",
                stderrPath: stderrPath ?? "/dev/null"
            )
        })
        let resolver = SubstitutingTemplateResolver()
        let runner = makeRunner(
            templateResolver: resolver,
            processRunner: fakeProcess,
            basePath: tempDir
        )

        _ = try await runner.evaluate(
            name: "nested_workflow",
            lastOutput: "output",
            context: makeContext()
        )

        #expect(fakeProcess.executedCommands.count == 1)
        // The SubstitutingTemplateResolver replaces {{workspace}} with the workspace path.
        #expect(fakeProcess.executedCommands[0].contains("/tmp/test/workflows/check.yml"))
    }

    // MARK: - Built-in Evaluator Priority

    @Test("Built-in evaluator 'approved' takes priority over custom YAML file")
    func builtInPriority() async throws {
        // Even if an approved.yml exists, the built-in evaluator should be used.
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Create a custom "approved" evaluator that would return different results.
        let yaml = """
        name: approved
        type: script
        command: "exit 1"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("approved.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let fakeProcess = FakeProcessRunner(exitCode: 1)
        let runner = makeRunner(processRunner: fakeProcess, basePath: tempDir)

        // Built-in "approved" should return true for "yes", ignoring the YAML file.
        let result = try await runner.evaluate(
            name: "approved",
            lastOutput: "yes",
            context: makeContext()
        )
        #expect(result == true)

        // The process runner should NOT have been called (built-in takes priority).
        #expect(fakeProcess.executedCommands.isEmpty)
    }

    // MARK: - File Loading

    @Test("loadEvaluatorDefinition loads from .orc/evaluators/ directory")
    func loadFromDisk() throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        let evaluatorsDir = (tempDir as NSString).appendingPathComponent("evaluators")
        try FileManager.default.createDirectory(atPath: evaluatorsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yaml = """
        name: my_evaluator
        type: script
        command: "echo hello"
        """
        let yamlPath = (evaluatorsDir as NSString).appendingPathComponent("my_evaluator.yml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let runner = makeRunner(basePath: tempDir)
        let definition = try runner.loadEvaluatorDefinition(name: "my_evaluator")

        #expect(definition.name == "my_evaluator")
        #expect(definition.type == .script)
        #expect(definition.command == "echo hello")
    }

    @Test("loadEvaluatorDefinition throws evaluatorNotFound for missing file")
    func loadMissingFile() throws {
        let tempDir = NSTemporaryDirectory() + "orc-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let runner = makeRunner(basePath: tempDir)
        #expect(throws: EngineError.self) {
            try runner.loadEvaluatorDefinition(name: "nonexistent")
        }
    }
}

// MARK: - Test Helpers

/// A template resolver that no-ops (returns the template unchanged).
/// Used by the original built-in evaluator tests.
private struct FakeTemplateResolver: TemplateResolving, Sendable {
    func resolve(template: String, context: TaskContext) throws -> String {
        template
    }
}

/// A template resolver that actually substitutes {{variable}} patterns
/// by looking up keys in the context's outputs and inputs dictionaries.
/// This is used by custom evaluator tests to verify template resolution works end-to-end.
private struct SubstitutingTemplateResolver: TemplateResolving, Sendable {
    func resolve(template: String, context: TaskContext) throws -> String {
        var result = template
        // Replace {{key}} patterns with values from outputs, then inputs.
        let allValues = context.outputs.merging(context.inputs) { outputVal, _ in outputVal }
        for (key, value) in allValues {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
