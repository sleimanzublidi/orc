import Testing
import Models
@testable import Parser

/// Tests for Resolvable field parsing in WorkflowParser — verifying that literal
/// values and template expressions are correctly mapped to Resolvable types,
/// and that invalid field types produce the expected errors.
@Suite("WorkflowParser - Resolvable Parsing")
struct ResolvableParsingTests {

    let parser = WorkflowParser()

    // MARK: - String Fields (agent)

    @Test("Literal agent string parses as .literal")
    func literalAgentString() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].agent == .literal("claude-code"))
    }

    @Test("Template agent string parses as .template")
    func templateAgentString() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: "{{agent_name}}"
            prompt: "Do work"
        input:
          - name: agent_name
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].agent == .template("{{agent_name}}"))
    }

    // MARK: - Int Fields (timeout_seconds)

    @Test("Literal timeout_seconds parses as .literal")
    func literalTimeoutSeconds() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            timeout_seconds: 300
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].timeoutSeconds == .literal(300))
    }

    @Test("Template timeout_seconds parses as .template")
    func templateTimeoutSeconds() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            timeout_seconds: "{{timeout}}"
        input:
          - name: timeout
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].timeoutSeconds == .template("{{timeout}}"))
    }

    @Test("Non-integer non-template timeout_seconds throws invalidFieldType")
    func invalidTimeoutSeconds() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            timeout_seconds: "not-a-number"
        """

        #expect(throws: ParserError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    // MARK: - Enum Fields (on_failure)

    @Test("Literal on_failure parses as .literal")
    func literalOnFailure() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            on_failure: skip
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].onFailure == .literal(.skip))
    }

    @Test("Template on_failure parses as .template")
    func templateOnFailure() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            on_failure: "{{failure_strategy}}"
        input:
          - name: failure_strategy
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].onFailure == .template("{{failure_strategy}}"))
    }

    @Test("Invalid on_failure value throws invalidExpression")
    func invalidOnFailure() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            on_failure: explode
        """

        #expect(throws: ParserError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    // MARK: - Enum Fields (workspace)

    @Test("Literal workspace parses as .literal")
    func literalWorkspace() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            workspace: isolated
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].workspaceMode == .literal(.isolated))
    }

    @Test("Template workspace parses as .template")
    func templateWorkspace() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            workspace: "{{ws_mode}}"
        input:
          - name: ws_mode
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].workspaceMode == .template("{{ws_mode}}"))
    }

    // MARK: - Parameters (provider-specific key-value pairs)

    @Test("Literal parameter parses as .literal")
    func literalParameter() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            parameters:
              permission_mode: dontAsk
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].parameters["permission_mode"] == .literal("dontAsk"))
    }

    @Test("Template parameter parses as .template")
    func templateParameter() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            parameters:
              permission_mode: "{{perm}}"
        input:
          - name: perm
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].parameters["permission_mode"] == .template("{{perm}}"))
    }

    // MARK: - Loop Config

    @Test("Literal loop max_iterations parses as .literal")
    func literalLoopMaxIterations() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            loop:
              prompt: "iterate"
              until: done
              max_iterations: 20
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.maxIterations == .literal(20))
    }

    @Test("Template loop max_iterations parses as .template")
    func templateLoopMaxIterations() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            loop:
              prompt: "iterate"
              until: done
              max_iterations: "{{max_iter}}"
        input:
          - name: max_iter
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.maxIterations == .template("{{max_iter}}"))
    }

    @Test("Literal loop fresh_context parses as .literal")
    func literalLoopFreshContext() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            loop:
              prompt: "iterate"
              until: done
              fresh_context: true
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.freshContext == .literal(true))
    }

    @Test("Template loop fresh_context parses as .template")
    func templateLoopFreshContext() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            loop:
              prompt: "iterate"
              until: done
              fresh_context: "{{fresh}}"
        input:
          - name: fresh
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.freshContext == .template("{{fresh}}"))
    }

    // MARK: - Retry Config

    @Test("Literal retry max_attempts parses as .literal")
    func literalRetryMaxAttempts() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            retry:
              max_attempts: 5
              delay_seconds: 10
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].retry?.maxAttempts == .literal(5))
        #expect(workflow.nodes[0].retry?.delaySeconds == .literal(10))
    }

    @Test("Template retry max_attempts parses as .template")
    func templateRetryMaxAttempts() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            retry:
              max_attempts: "{{retries}}"
              delay_seconds: "{{delay}}"
        input:
          - name: retries
          - name: delay
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].retry?.maxAttempts == .template("{{retries}}"))
        #expect(workflow.nodes[0].retry?.delaySeconds == .template("{{delay}}"))
    }

    // MARK: - Default Values

    @Test("Default on_failure is .literal(.stop)")
    func defaultOnFailure() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].onFailure == .literal(.stop))
    }

    @Test("Default loop max_iterations is .literal(10)")
    func defaultLoopMaxIterations() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            loop:
              prompt: "iterate"
              until: done
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.maxIterations == .literal(10))
    }

    @Test("Default loop fresh_context is .literal(false)")
    func defaultLoopFreshContext() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            loop:
              prompt: "iterate"
              until: done
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.freshContext == .literal(false))
    }

    @Test("Default retry max_attempts is .literal(1) and delay_seconds is .literal(0)")
    func defaultRetryValues() throws {
        let yaml = """
        name: "test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            retry: {}
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].retry?.maxAttempts == .literal(1))
        #expect(workflow.nodes[0].retry?.delaySeconds == .literal(0))
    }

    // MARK: - Input Default Value

    @Test("Input with default value parses correctly")
    func inputWithDefaultValue() throws {
        let yaml = """
        name: "test"
        input:
          - name: timeout
            type: string
            required: false
            default: "300"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.input[0].defaultValue == "300")
        #expect(workflow.input[0].required == false)
    }

    @Test("Input without default value has nil defaultValue")
    func inputWithoutDefaultValue() throws {
        let yaml = """
        name: "test"
        input:
          - name: path
            type: string
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work in {{path}}"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.input[0].defaultValue == nil)
    }

    // MARK: - Template String Collection

    @Test("collectTemplateStrings scans Resolvable template fields for validation")
    func templateFieldsValidated() throws {
        // Resolvable template fields with unknown variables should be caught
        // by the parser's template variable validation.
        let yaml = """
        name: "test"
        input:
          - name: known_var
        nodes:
          - id: step1
            agent: "{{unknown_agent}}"
            prompt: "Do work"
        """

        // The parser should flag {{unknown_agent}} as referencing an unknown name.
        #expect(throws: ParserError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    @Test("Known template variables in Resolvable fields pass validation")
    func knownTemplateFieldsPass() throws {
        let yaml = """
        name: "test"
        input:
          - name: agent_name
        nodes:
          - id: step1
            agent: "{{agent_name}}"
            prompt: "Do work"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].agent == .template("{{agent_name}}"))
    }

    // MARK: - Nested Workflow Without Inputs

    @Test("Workflow node with no inputs mapping parses successfully")
    func workflowNodeWithoutInputsMapping() throws {
        // A workflow node that references a child workflow without providing
        // an inputs mapping should parse successfully. The child may have all
        // inputs with default values, so no explicit inputs are required.
        // The engine validates required inputs at runtime.
        let yaml = """
        name: "parent"
        nodes:
          - id: nest
            workflow: child.yml
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].id == "nest")
        #expect(workflow.nodes[0].workflow == "child.yml")
        #expect(workflow.nodes[0].inputs == nil)
    }

    @Test("Workflow node with empty inputs mapping parses successfully")
    func workflowNodeWithEmptyInputsMapping() throws {
        let yaml = """
        name: "parent"
        nodes:
          - id: nest
            workflow: child.yml
            inputs: {}
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].id == "nest")
        #expect(workflow.nodes[0].workflow == "child.yml")
        #expect(workflow.nodes[0].inputs?.isEmpty == true)
    }

    // MARK: - invalidFieldType Error

    @Test("ParserError.invalidFieldType has correct LocalizedError description")
    func invalidFieldTypeDescription() {
        let error = ParserError.invalidFieldType(
            node: "step1", field: "timeout_seconds", expected: "integer or template string"
        )
        #expect(error.description == "[step1] Field 'timeout_seconds' has invalid type; expected integer or template string")
        #expect(error.localizedDescription == error.description)
    }

    // MARK: - prompt_file

    @Test("prompt_file is parsed from YAML")
    func promptFileIsParsed() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt_file: "{{orc_root}}/prompts/review.md"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].promptFile == "{{orc_root}}/prompts/review.md")
        #expect(workflow.nodes[0].prompt == nil)
    }

    @Test("prompt takes precedence over prompt_file")
    func promptTakesPrecedenceOverPromptFile() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt: "inline prompt"
            prompt_file: "/some/file.md"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].prompt == "inline prompt")
        #expect(workflow.nodes[0].promptFile == "/some/file.md")
    }
}
