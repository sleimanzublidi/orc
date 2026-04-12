import ArgumentParser
import Engine
import Foundation
import Logging
import Models

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a workflow run"
    )

    @Argument(help: "Path to the workflow YAML file.")
    var workflowFile: String

    @Option(name: .long, parsing: .upToNextOption, help: "Input values (key=value or raw value).")
    var input: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "File paths (assigned to the first 'type: file' input).")
    var file: [String] = []

    @Option(name: .long, help: "Maximum parallel nodes.")
    var maxParallelNodes: Int?

    @Flag(name: .long, help: "Enable verbose output (debug-level logging).")
    var verbose: Bool = false

    @Flag(name: .long, help: "Send a macOS notification when the run completes.")
    var notify: Bool = false

    @Option(name: .long, help: "Shell command to execute when the run completes.")
    var onComplete: String?

    @Argument(parsing: .allUnrecognized, help: .hidden)
    var rawInput: [String] = []

    func run() async throws {
        let basePath = try OrcDirectory.require()

        // Read config to check output.verbose setting.
        let configManager = ConfigManager(basePath: basePath)
        let config = try configManager.loadConfig()
        let isVerbose = verbose || config.verbose

        // Bootstrap swift-log before any Logger instances are created.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = isVerbose ? .debug : .info
            return handler
        }

        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        do {
            let resolvedFile = OrcDirectory.resolveWorkflowFile(workflowFile, basePath: engine.basePath)

            // Build inputs: key=value pairs, raw values, and file paths.
            let inputs = try await Self.parseInputs(
                input, rawInput: rawInput, files: file,
                engine: engine, workflowFile: resolvedFile
            )

            print("Running workflow \(resolvedFile)")
            let startTime = Date()
            let run = try await engine.start(
                workflowFile: resolvedFile,
                inputs: inputs,
                maxParallelNodes: maxParallelNodes
            )
            let elapsedSeconds = Date().timeIntervalSince(startTime)

            defer { runCompletionHooks(run: run, elapsedSeconds: elapsedSeconds) }

            print("Workflow run \(run.id) \(Format.statusIndicator(run.status))")
            if run.status == .failed {
                // Show the first failed node's error so the user knows what went wrong.
                let executions = try await engine.getNodeExecutions(runID: run.id, nodeID: nil)
                for exec in executions where exec.status == .failed {
                    let nodeLabel = "[\(exec.nodeID)]"
                    if let error = exec.error {
                        Format.printError("  \(nodeLabel) \(error)")
                    } else {
                        Format.printError("  \(nodeLabel) failed (no details)")
                    }
                }
            } else if let output = run.output {
                print("Output: \(output)")
            } else if run.status == .completed {
                // No workflow-level output mapping — show last node's output.
                let executions = try await engine.getNodeExecutions(runID: run.id, nodeID: nil)
                if let lastOutput = executions.last(where: { $0.status == .completed })?.output {
                    print("Output: \(lastOutput)")
                }
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
    /// Parses an array of strings into key=value pairs and raw (non-pair) parts.
    ///
    /// Splits on the first `=` character so values can contain `=`.
    /// Items without `=` are returned in `rawParts`.
    static func parseInputPairs(_ pairs: [String]) throws -> (pairs: [String: String], rawParts: [String]) {
        var result: [String: String] = [:]
        var rawParts: [String] = []

        for item in pairs {
            if item.contains("=") {
                let eqIndex = item.firstIndex(of: "=")!
                let key = String(item[item.startIndex..<eqIndex])
                let value = String(item[item.index(after: eqIndex)...])
                guard !key.isEmpty else {
                    Format.printError("Invalid input: empty key in '\(item)'.")
                    throw ExitCode.failure
                }
                result[key] = value
            } else {
                rawParts.append(item)
            }
        }

        return (result, rawParts)
    }

    /// Parses --input values, raw trailing arguments, and --file paths into a dictionary.
    ///
    /// - key=value items in `input` become direct entries
    /// - Non-key=value items in `input` and all `rawInput` items are joined
    ///   with spaces and assigned to the workflow's first `type: string` input
    /// - `files` are resolved to absolute paths and assigned to `type: file` inputs
    ///   in declaration order
    static func parseInputs(
        _ input: [String],
        rawInput: [String],
        files: [String],
        engine: some OrcEngineProviding,
        workflowFile: String
    ) async throws -> [String: String] {
        let (parsed, inputRawParts) = try parseInputPairs(input)
        var result = parsed
        var rawParts = inputRawParts

        rawParts.append(contentsOf: rawInput)

        let needsWorkflow = !rawParts.isEmpty || !files.isEmpty
        var workflow: Workflow?

        if needsWorkflow {
            let (w, _) = try await engine.validate(workflowFile: workflowFile)
            workflow = w
        }

        // Assign raw text to the first string input not already set.
        if !rawParts.isEmpty {
            guard let w = workflow else {
                Format.printError("Workflow has no inputs to assign raw value to.")
                throw ExitCode.failure
            }
            let firstString = w.input.first { $0.type == "string" && result[$0.name] == nil }
                ?? w.input.first { result[$0.name] == nil }
            guard let target = firstString else {
                Format.printError("Workflow has no available input to assign raw value to.")
                throw ExitCode.failure
            }
            result[target.name] = rawParts.joined(separator: " ")
        }

        // Assign file paths to type: file inputs in declaration order.
        if !files.isEmpty {
            guard let w = workflow else {
                Format.printError("Workflow has no file inputs.")
                throw ExitCode.failure
            }
            let fileInputs = w.input.filter { $0.type == "file" && result[$0.name] == nil }
            guard fileInputs.count >= files.count else {
                let available = fileInputs.count
                Format.printError(
                    "Workflow has \(available) file input(s) but \(files.count) file(s) were provided."
                )
                throw ExitCode.failure
            }

            let fm = FileManager.default
            for (fileInput, path) in zip(fileInputs, files) {
                // Resolve to absolute path.
                let absolute: String
                if (path as NSString).isAbsolutePath {
                    absolute = path
                } else {
                    absolute = (fm.currentDirectoryPath as NSString).appendingPathComponent(path)
                }

                guard fm.fileExists(atPath: absolute) else {
                    Format.printError("File not found: \(path)")
                    throw ExitCode.failure
                }

                result[fileInput.name] = absolute
            }
        }

        return result
    }
}

// MARK: - Completion Hooks

extension StartCommand {

    /// Builds the AppleScript for a macOS notification.
    static func notificationScript(run: Run, elapsedSeconds: Double) -> String {
        let title = run.status == .completed ? "Orc \u{2014} Completed" : "Orc \u{2014} Failed"
        let body = "Run \(run.id) \(run.status.rawValue) in \(Format.duration(elapsedSeconds))"
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        return "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
    }

    /// Builds the environment dictionary for an on-complete hook command.
    static func completionEnvironment(run: Run, elapsedSeconds: Double) -> [String: String] {
        [
            "ORC_RUN_ID": run.id,
            "ORC_STATUS": run.status.rawValue,
            "ORC_ELAPSED_SECONDS": String(Int(elapsedSeconds)),
            "ORC_WORKFLOW_NAME": run.workflowName,
        ]
    }

    private func runCompletionHooks(run: Run, elapsedSeconds: Double) {
        if notify {
            #if os(macOS)
            let script = Self.notificationScript(run: run, elapsedSeconds: elapsedSeconds)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Format.printError("Warning: Failed to send notification: \(error)")
            }
            #else
            Format.printError("Warning: --notify is only supported on macOS (osascript not available)")
            #endif
        }

        if let command = onComplete {
            let env = Self.completionEnvironment(run: run, elapsedSeconds: elapsedSeconds)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Format.printError("Warning: Failed to run on-complete command: \(error)")
            }
        }
    }
}
