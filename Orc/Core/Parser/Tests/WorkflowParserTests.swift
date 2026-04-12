import Testing
import Models
@testable import Parser

// MARK: - Valid Workflow Round-Trips

@Suite("WorkflowParser - Valid Workflows")
struct ValidWorkflowTests {

    let parser = WorkflowParser()

    @Test("Full workflow with all fields")
    func fullWorkflow() throws {
        let yaml = """
        name: "full-workflow"
        description: "A workflow with every field"
        input:
          - name: repo_path
            type: string
            required: true
          - name: branch
            type: string
            required: false
        nodes:
          - id: plan
            agent: claude-code
            prompt: "Create a plan for {{repo_path}}"
            output: plan_file
            timeout_seconds: 300
            retry:
              max_attempts: 2
              delay_seconds: 5
            on_failure: skip
          - id: implement
            agent: claude-code
            depends_on: [plan]
            prompt: "Implement {{plan_file}}"
            when: "{{plan.status}} == 'completed'"
            workspace: isolated
          - id: review
            agent: claude-code
            depends_on: [implement]
            interactive: session
            prompt: "Review changes"
        output:
          summary: "{{review.output}}"
        cleanup: on_success
        """

        let workflow = try parser.parse(yaml: yaml)

        #expect(workflow.name == "full-workflow")
        #expect(workflow.description == "A workflow with every field")
        #expect(workflow.input.count == 2)
        #expect(workflow.input[0].name == "repo_path")
        #expect(workflow.input[0].type == "string")
        #expect(workflow.input[0].required == true)
        #expect(workflow.input[1].name == "branch")
        #expect(workflow.input[1].required == false)
        #expect(workflow.nodes.count == 3)
        #expect(workflow.output?["summary"] == "{{review.output}}")
        #expect(workflow.cleanupPolicy == .onSuccess)

        // Plan node
        let plan = workflow.nodes[0]
        #expect(plan.id == "plan")
        #expect(plan.agent == .literal("claude-code"))
        #expect(plan.prompt == "Create a plan for {{repo_path}}")
        #expect(plan.output == "plan_file")
        #expect(plan.timeoutSeconds == .literal(300))
        #expect(plan.retry?.maxAttempts == .literal(2))
        #expect(plan.retry?.delaySeconds == .literal(5))
        #expect(plan.onFailure == .literal(.skip))
        #expect(plan.dependsOn.isEmpty)

        // Implement node
        let implement = workflow.nodes[1]
        #expect(implement.id == "implement")
        #expect(implement.dependsOn == ["plan"])
        #expect(implement.when == "{{plan.status}} == 'completed'")
        #expect(implement.workspaceMode == .literal(.isolated))

        // Review node
        let review = workflow.nodes[2]
        #expect(review.id == "review")
        #expect(review.interactive == .session)
        #expect(review.dependsOn == ["implement"])
    }

    @Test("Minimal workflow with defaults")
    func minimalWorkflow() throws {
        let yaml = """
        name: "minimal"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do something"
        """

        let workflow = try parser.parse(yaml: yaml)

        #expect(workflow.name == "minimal")
        #expect(workflow.description == nil)
        #expect(workflow.input.isEmpty)
        #expect(workflow.nodes.count == 1)
        #expect(workflow.output == nil)
        #expect(workflow.cleanupPolicy == .duration(days: 30))

        let node = workflow.nodes[0]
        #expect(node.id == "step1")
        #expect(node.agent == .literal("claude-code"))
        #expect(node.dependsOn.isEmpty)
        #expect(node.onFailure == .literal(.stop))
        #expect(node.interactive == nil)
        #expect(node.loop == nil)
        #expect(node.retry == nil)
        #expect(node.timeoutSeconds == nil)
        #expect(node.workflow == nil)
        #expect(node.inputs == nil)
        #expect(node.workspaceMode == nil)
        #expect(node.permissionMode == nil)
    }

    @Test("Node with permission_mode")
    func permissionMode() throws {
        let yaml = """
        name: "perm-test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do something"
            permission_mode: full
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].permissionMode == .literal(.full))
    }

    @Test("Invalid permission_mode throws")
    func invalidPermissionMode() throws {
        let yaml = """
        name: "perm-test"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do something"
            permission_mode: invalid
        """

        #expect(throws: ParserError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    @Test("Workflow with loop config including prompt inside loop block")
    func loopConfig() throws {
        let yaml = """
        name: "loop-test"
        nodes:
          - id: iterate
            agent: claude-code
            loop:
              prompt: "Do iteration work"
              until: all_done
              max_iterations: 20
              fresh_context: true
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.prompt == "Do iteration work")
        #expect(node.loop?.until == "all_done")
        #expect(node.loop?.maxIterations == .literal(20))
        #expect(node.loop?.freshContext == .literal(true))
    }

    @Test("Workflow with interactive session node")
    func interactiveSession() throws {
        let yaml = """
        name: "session-test"
        nodes:
          - id: debug
            agent: claude-code
            interactive: session
            prompt: "Debug the issue"
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.interactive == .session)
        #expect(node.prompt == "Debug the issue")
    }

    @Test("Workflow with interactive prompt node with message")
    func interactivePrompt() throws {
        let yaml = """
        name: "prompt-test"
        nodes:
          - id: ask
            agent: claude-code
            interactive: prompt
            message: "Should we continue?"
            prompt: "Waiting for approval"
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.interactive == .prompt(message: "Should we continue?"))
    }

    @Test("Workflow with nested workflow node")
    func nestedWorkflow() throws {
        let yaml = """
        name: "nested-test"
        nodes:
          - id: sub
            workflow: "./sub-workflow.yaml"
            inputs:
              path: "{{workspace}}"
            workspace: isolated
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.workflow == "./sub-workflow.yaml")
        #expect(node.inputs?["path"] == "{{workspace}}")
        #expect(node.workspaceMode == .literal(.isolated))
    }

    @Test("Workflow with output aliases")
    func outputAliases() throws {
        let yaml = """
        name: "alias-test"
        nodes:
          - id: generate
            agent: claude-code
            prompt: "Generate code"
            output: generated_code
        output:
          result: "{{generated_code}}"
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.output == "generated_code")
        #expect(workflow.output?["result"] == "{{generated_code}}")
    }

    @Test("Workflow with when conditions")
    func whenCondition() throws {
        let yaml = """
        name: "when-test"
        nodes:
          - id: first
            agent: claude-code
            prompt: "First task"
          - id: second
            agent: claude-code
            depends_on: [first]
            prompt: "Second task"
            when: "{{first.status}} == 'completed'"
        """

        let workflow = try parser.parse(yaml: yaml)
        let second = workflow.nodes[1]

        #expect(second.when == "{{first.status}} == 'completed'")
    }

    @Test("Workflow with retry and timeout config")
    func retryAndTimeout() throws {
        let yaml = """
        name: "retry-test"
        nodes:
          - id: flaky
            agent: claude-code
            prompt: "Run flaky task"
            retry:
              max_attempts: 5
              delay_seconds: 10
            timeout_seconds: 600
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.retry?.maxAttempts == .literal(5))
        #expect(node.retry?.delaySeconds == .literal(10))
        #expect(node.timeoutSeconds == .literal(600))
    }

    @Test("Workflow with cleanup policy")
    func cleanupPolicy() throws {
        let yaml = """
        name: "cleanup-test"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
        cleanup: never
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.cleanupPolicy == .never)
    }

    @Test("Cleanup policy with duration format")
    func cleanupDuration() throws {
        let yaml = """
        name: "cleanup-duration"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
        cleanup: "7d"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.cleanupPolicy == .duration(days: 7))
    }

    @Test("Workflow with on_failure continue")
    func onFailureContinue() throws {
        let yaml = """
        name: "failure-test"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
            on_failure: continue
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].onFailure == .literal(.continue))
    }
}

// MARK: - Validation Errors

@Suite("WorkflowParser - Validation Errors")
struct ValidationErrorTests {

    let parser = WorkflowParser()

    @Test("Missing name produces error")
    func missingName() {
        let yaml = """
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Empty nodes list produces error")
    func emptyNodes() {
        let yaml = """
        name: "empty-nodes"
        nodes: []
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Node missing id produces error")
    func nodeMissingID() {
        let yaml = """
        name: "missing-id"
        nodes:
          - agent: claude-code
            prompt: "No id here"
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Duplicate node IDs produce error")
    func duplicateNodeIDs() throws {
        let yaml = """
        name: "duplicate-ids"
        nodes:
          - id: step
            agent: claude-code
            prompt: "First"
          - id: step
            agent: claude-code
            prompt: "Second"
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("depends_on references nonexistent node")
    func invalidDependsOn() {
        let yaml = """
        name: "bad-ref"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
            depends_on: [nonexistent]
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Circular dependency A -> B -> A detected")
    func circularDependencySimple() {
        let yaml = """
        name: "cycle"
        nodes:
          - id: a
            agent: claude-code
            prompt: "A"
            depends_on: [b]
          - id: b
            agent: claude-code
            prompt: "B"
            depends_on: [a]
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Self-referencing node detected")
    func selfReference() {
        let yaml = """
        name: "self-ref"
        nodes:
          - id: loop_node
            agent: claude-code
            prompt: "I depend on myself"
            depends_on: [loop_node]
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Deep cycle A -> B -> C -> A detected")
    func deepCycle() {
        let yaml = """
        name: "deep-cycle"
        nodes:
          - id: a
            agent: claude-code
            prompt: "A"
            depends_on: [c]
          - id: b
            agent: claude-code
            prompt: "B"
            depends_on: [a]
          - id: c
            agent: claude-code
            prompt: "C"
            depends_on: [b]
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Non-interactive node without agent produces error")
    func missingAgent() throws {
        // Node has no agent, no command, no workflow, and is not interactive
        let yaml = """
        name: "no-agent"
        nodes:
          - id: orphan
            prompt: "I have no agent"
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Interactive prompt without message produces error")
    func interactivePromptWithoutMessage() {
        let yaml = """
        name: "no-message"
        nodes:
          - id: ask
            agent: claude-code
            interactive: prompt
            prompt: "Waiting"
        """

        // The node has interactive: prompt but no "message" field, so message is ""
        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Output alias collides with node id produces error")
    func outputAliasCollidesWithNodeID() {
        let yaml = """
        name: "alias-collision"
        nodes:
          - id: plan
            agent: claude-code
            prompt: "Plan"
          - id: execute
            agent: claude-code
            prompt: "Execute"
            output: plan
            depends_on: [plan]
        """

        // Alias collision with a node id is now an error, so parsing should throw.
        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Invalid on_failure value produces error")
    func invalidOnFailure() {
        let yaml = """
        name: "bad-failure"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
            on_failure: explode
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Malformed YAML produces yamlSyntax error")
    func malformedYAML() {
        let yaml = """
        name: "broken
          - invalid: [yaml
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }
}

// MARK: - Template Variable Validation

@Suite("WorkflowParser - Template Variable Validation")
struct TemplateVariableTests {

    let parser = WorkflowParser()

    @Test("Valid variable references pass validation")
    func validVariableReferences() throws {
        let yaml = """
        name: "valid-refs"
        input:
          - name: repo_path
            type: string
        nodes:
          - id: plan
            agent: claude-code
            prompt: "Plan for {{repo_path}}"
            output: plan_file
          - id: implement
            agent: claude-code
            depends_on: [plan]
            prompt: "Implement using {{plan_file}} and {{plan.output}} with status {{plan.status}}"
        """

        let workflow = try parser.parse(yaml: yaml)
        let result = parser.validate(workflow: workflow)

        #expect(result.isValid)
    }

    @Test("Invalid variable reference to nonexistent node produces error")
    func invalidVariableReference() throws {
        let yaml = """
        name: "bad-ref"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Use {{nonexistent_var}}"
        """

        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }

    @Test("Workspace built-in variable is valid")
    func workspaceBuiltinValid() throws {
        let yaml = """
        name: "workspace-ref"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Work in {{workspace}}"
        """

        let workflow = try parser.parse(yaml: yaml)
        let result = parser.validate(workflow: workflow)
        #expect(result.isValid)
    }

    @Test("last_output built-in variable is valid")
    func lastOutputBuiltinValid() throws {
        let yaml = """
        name: "last-output-ref"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Previous was {{last_output}}"
        """

        let workflow = try parser.parse(yaml: yaml)
        let result = parser.validate(workflow: workflow)
        #expect(result.isValid)
    }
}

// MARK: - Edge Cases

@Suite("WorkflowParser - Edge Cases")
struct EdgeCaseTests {

    let parser = WorkflowParser()

    @Test("Node with no depends_on fires immediately")
    func noDependencies() throws {
        let yaml = """
        name: "immediate"
        nodes:
          - id: fast
            agent: claude-code
            prompt: "Run immediately"
        """

        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].dependsOn.isEmpty)
    }

    @Test("Diamond dependency pattern is valid")
    func diamondDependency() throws {
        let yaml = """
        name: "diamond"
        nodes:
          - id: a
            agent: claude-code
            prompt: "Start"
          - id: b
            agent: claude-code
            depends_on: [a]
            prompt: "Branch 1"
          - id: c
            agent: claude-code
            depends_on: [a]
            prompt: "Branch 2"
          - id: d
            agent: claude-code
            depends_on: [b, c]
            prompt: "Merge"
        """

        let workflow = try parser.parse(yaml: yaml)
        let result = parser.validate(workflow: workflow)

        #expect(result.isValid)
        #expect(workflow.nodes.count == 4)
    }

    @Test("Disconnected parallel branches are valid")
    func disconnectedBranches() throws {
        let yaml = """
        name: "parallel"
        nodes:
          - id: branch_a
            agent: claude-code
            prompt: "Independent A"
          - id: branch_b
            agent: claude-code
            prompt: "Independent B"
          - id: branch_c
            agent: claude-code
            prompt: "Independent C"
        """

        let workflow = try parser.parse(yaml: yaml)
        let result = parser.validate(workflow: workflow)

        #expect(result.isValid)
        #expect(workflow.nodes.count == 3)
    }

    @Test("Node with command does not require agent")
    func commandNodeNoAgent() throws {
        let yaml = """
        name: "command-test"
        nodes:
          - id: build
            command: "swift build"
        """

        let workflow = try parser.parse(yaml: yaml)
        let result = parser.validate(workflow: workflow)

        #expect(result.isValid)
        #expect(workflow.nodes[0].command == "swift build")
        #expect(workflow.nodes[0].agent == nil)
    }

    @Test("Loop config with default values")
    func loopDefaults() throws {
        let yaml = """
        name: "loop-defaults"
        nodes:
          - id: iterate
            agent: claude-code
            loop:
              prompt: "Iterate"
              until: done
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.loop?.maxIterations == .literal(10))
        #expect(node.loop?.freshContext == .literal(false))
    }

    @Test("Retry config with default values")
    func retryDefaults() throws {
        let yaml = """
        name: "retry-defaults"
        nodes:
          - id: step
            agent: claude-code
            prompt: "Do work"
            retry:
              max_attempts: 3
        """

        let workflow = try parser.parse(yaml: yaml)
        let node = workflow.nodes[0]

        #expect(node.retry?.maxAttempts == .literal(3))
        #expect(node.retry?.delaySeconds == .literal(0))
    }

    @Test("Output alias collides with input name produces error")
    func outputAliasCollidesWithInput() {
        let yaml = """
        name: "alias-input-collision"
        input:
          - name: my_input
        nodes:
          - id: step
            agent: claude-code
            prompt: "Use {{my_input}}"
            output: my_input
        """

        // Alias collision with an input name is now an error, so parsing should throw.
        #expect(throws: ParserError.self) {
            try parser.parse(yaml: yaml)
        }
    }
}

// MARK: - DAG Validator

@Suite("DAGValidator")
struct DAGValidatorTests {

    @Test("Topological sort of linear chain")
    func linearChain() throws {
        let nodes = [
            Node(id: "a", agent: .literal("x"), prompt: "A"),
            Node(id: "b", agent: .literal("x"), prompt: "B", dependsOn: ["a"]),
            Node(id: "c", agent: .literal("x"), prompt: "C", dependsOn: ["b"]),
        ]

        let sorted = try DAGValidator.topologicalSort(nodes: nodes)
        let aIdx = sorted.firstIndex(of: "a")!
        let bIdx = sorted.firstIndex(of: "b")!
        let cIdx = sorted.firstIndex(of: "c")!

        #expect(aIdx < bIdx)
        #expect(bIdx < cIdx)
    }

    @Test("Topological sort of diamond graph")
    func diamondGraph() throws {
        let nodes = [
            Node(id: "a", agent: .literal("x"), prompt: "A"),
            Node(id: "b", agent: .literal("x"), prompt: "B", dependsOn: ["a"]),
            Node(id: "c", agent: .literal("x"), prompt: "C", dependsOn: ["a"]),
            Node(id: "d", agent: .literal("x"), prompt: "D", dependsOn: ["b", "c"]),
        ]

        let sorted = try DAGValidator.topologicalSort(nodes: nodes)

        let aIdx = sorted.firstIndex(of: "a")!
        let bIdx = sorted.firstIndex(of: "b")!
        let cIdx = sorted.firstIndex(of: "c")!
        let dIdx = sorted.firstIndex(of: "d")!

        #expect(aIdx < bIdx)
        #expect(aIdx < cIdx)
        #expect(bIdx < dIdx)
        #expect(cIdx < dIdx)
    }

    @Test("Cycle detection throws with cycle info")
    func cycleDetection() {
        let nodes = [
            Node(id: "a", agent: .literal("x"), prompt: "A", dependsOn: ["b"]),
            Node(id: "b", agent: .literal("x"), prompt: "B", dependsOn: ["a"]),
        ]

        #expect(throws: ParserError.self) {
            try DAGValidator.topologicalSort(nodes: nodes)
        }
    }

    @Test("Independent nodes all appear in sorted output")
    func independentNodes() throws {
        let nodes = [
            Node(id: "x", agent: .literal("a"), prompt: "X"),
            Node(id: "y", agent: .literal("a"), prompt: "Y"),
            Node(id: "z", agent: .literal("a"), prompt: "Z"),
        ]

        let sorted = try DAGValidator.topologicalSort(nodes: nodes)
        #expect(sorted.count == 3)
        #expect(Set(sorted) == Set(["x", "y", "z"]))
    }
}
