import Foundation
import Models

/// A fake workflow parser for testing that returns pre-configured workflows.
///
/// Set `workflowToReturn` for a default workflow, or use `workflowsByFile` to
/// return different workflows based on the file path passed to `parse(file:)`.
/// This is essential for testing nested workflows where the parent's node
/// references a child workflow YAML file.
struct FakeWorkflowParser: WorkflowParsing, Sendable {
    /// The default workflow returned by parse methods when no file-specific
    /// override is configured.
    var workflowToReturn: Workflow

    /// Maps file paths to specific workflows. When `parse(file:)` is called,
    /// this dictionary is checked first before falling back to `workflowToReturn`.
    var workflowsByFile: [String: Workflow]

    /// If set, parse methods throw this error instead of returning a workflow.
    var errorToThrow: (any Error)?

    /// Maps file paths to specific errors. When `parse(file:)` is called with
    /// a matching path, that error is thrown instead of returning a workflow.
    var errorsByFile: [String: any Error]

    init(workflow: Workflow? = nil) {
        self.workflowToReturn = workflow ?? Workflow(
            name: "test-workflow",
            nodes: [
                Models.Node(id: "step1", agent: "fake", prompt: "do something")
            ]
        )
        self.workflowsByFile = [:]
        self.errorsByFile = [:]
    }

    func parse(yaml: String) throws -> Workflow {
        if let error = errorToThrow {
            throw error
        }
        return workflowToReturn
    }

    func parse(file: String) throws -> Workflow {
        // Check for file-specific errors first.
        if let error = errorsByFile[file] {
            throw error
        }

        // Check for a global error override.
        if let error = errorToThrow {
            throw error
        }

        // Check for a file-specific workflow.
        if let workflow = workflowsByFile[file] {
            return workflow
        }

        return workflowToReturn
    }

    func validate(workflow: Workflow) -> ValidationResult {
        ValidationResult()
    }
}
