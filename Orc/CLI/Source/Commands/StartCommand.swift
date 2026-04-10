import ArgumentParser
import Engine
import Models

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a workflow run"
    )

    @Argument(help: "Path to the workflow YAML file.")
    var workflowFile: String

    @Option(name: .long, parsing: .upToNextOption, help: "Input values (key=value).")
    var input: [String] = []

    @Option(name: .long, help: "Maximum parallel nodes.")
    var maxParallelNodes: Int?

    func run() async throws {
        do {
            let basePath = try OrcDirectory.require()
            let engine = try await WorkflowEngine(basePath: basePath)

            // Parse key=value input pairs.
            let inputs = try Self.parseInputPairs(input)

            let run = try await engine.start(
                workflowFile: workflowFile,
                inputs: inputs,
                maxParallelNodes: maxParallelNodes
            )

            print("Run \(run.id) \(Format.statusIndicator(run.status))")
            if let output = run.output {
                print("Output: \(output)")
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Format.printError("Error: \(error)")
            throw ExitCode.failure
        }
    }
}

extension StartCommand {
    /// Parses an array of "key=value" strings into a dictionary.
    ///
    /// Splits on the first `=` character so values can contain `=`.
    static func parseInputPairs(_ pairs: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for pair in pairs {
        guard let eqIndex = pair.firstIndex(of: "=") else {
            Format.printError("Invalid input format '\(pair)'. Expected key=value.")
            throw ExitCode.failure
        }
        let key = String(pair[pair.startIndex..<eqIndex])
        let value = String(pair[pair.index(after: eqIndex)...])
        guard !key.isEmpty else {
            Format.printError("Invalid input: empty key in '\(pair)'.")
            throw ExitCode.failure
        }
        result[key] = value
        }
        return result
    }
}
