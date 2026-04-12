import Foundation
import Models
import Providers

/// A fake agent provider that returns canned outputs for testing.
///
/// Configure `outputs` with node-prompt-to-output mappings, or set a
/// `defaultOutput` that all calls return. Can also simulate failures.
final class FakeAgentProvider: AgentProviding, @unchecked Sendable {
    let name: String

    /// Maps prompt substrings to canned outputs. If a prompt contains the key,
    /// the corresponding output is returned.
    var outputs: [String: String] = [:]

    /// Default output returned when no prompt substring matches.
    var defaultOutput: String = "fake output"

    /// If set, the provider throws this error instead of returning output.
    var errorToThrow: (any Error)?

    /// If set, executeStreaming() yields these events. Otherwise falls back to wrapping execute().
    var streamEvents: [AgentStreamEvent]?

    /// Records all prompts that were executed, in order.
    private(set) var executedPrompts: [String] = []

    /// Records all interactive calls.
    private(set) var interactiveCalls: [(prompt: String, sessionName: String)] = []

    init(name: String = "fake") {
        self.name = name
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil, parameters: [String: String] = [:]) async throws -> TaskOutput {
        executedPrompts.append(prompt)

        if let error = errorToThrow {
            throw error
        }

        for (key, output) in outputs {
            if prompt.contains(key) {
                return TaskOutput(output: output, exitStatus: 0)
            }
        }

        return TaskOutput(output: defaultOutput, exitStatus: 0)
    }

    func executeStreaming(
        prompt: String,
        context: TaskContext,
        timeout: Int? = nil,
        parameters: [String: String] = [:]
    ) -> AsyncThrowingStream<AgentStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let events = self.streamEvents {
                        for event in events {
                            continuation.yield(event)
                        }
                    } else {
                        let output = try await self.execute(
                            prompt: prompt, context: context,
                            timeout: timeout, parameters: parameters
                        )
                        continuation.yield(.completed(output))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func executeInteractive(
        prompt: String,
        context: TaskContext,
        sessionName: String,
        timeout: Int? = nil
    ) async throws -> TaskOutput {
        interactiveCalls.append((prompt: prompt, sessionName: sessionName))

        if let error = errorToThrow {
            throw error
        }

        return TaskOutput(output: "", exitStatus: 0)
    }
}
