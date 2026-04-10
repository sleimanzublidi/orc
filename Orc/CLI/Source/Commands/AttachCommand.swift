import ArgumentParser
import Engine
import Foundation

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach to an interactive node's tmux session"
    )

    @Argument(help: "Run ID.")
    var runID: String

    @Argument(help: "Node ID.")
    var nodeID: String

    func run() async throws {
        do {
            // Verify we are inside an Orc project.
            let basePath = try OrcDirectory.require()
            let engine = try await WorkflowEngine(basePath: basePath)

            // Verify the node execution exists and is in awaitingInput state.
            let executions = try await engine.getNodeExecutions(runID: runID, nodeID: nodeID)
            guard let latest = executions.last else {
                Format.printError("No execution found for node '\(nodeID)' in run '\(runID)'.")
                throw ExitCode.failure
            }

            guard latest.status == .awaitingInput else {
                Format.printError(
                    "Node '\(nodeID)' is not awaiting input (current status: \(latest.status.rawValue))."
                )
                throw ExitCode.failure
            }

            // Verify this is a session-interactive node (has a tmux session).
            // Prompt-interactive nodes should use `orc respond` instead.
            guard let sessionName = latest.tmuxSession else {
                Format.printError(
                    "Node '\(nodeID)' is a prompt-interactive node. Use 'orc respond \(runID) \(nodeID) <response>' instead."
                )
                throw ExitCode.failure
            }

            // Replace the current process with tmux attach-session.
            // This is intentional: execvp does not return on success.
            let args = ["tmux", "attach-session", "-t", sessionName]
            let cArgs = args.map { strdup($0) } + [nil]
            defer { cArgs.forEach { free($0) } }

            execvp("tmux", cArgs)

            // If execvp returns, it failed.
            Format.printError("Failed to attach to tmux session '\(sessionName)'. Is tmux installed?")
            throw ExitCode.failure
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
