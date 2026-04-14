import Foundation
import Models
import Providers

/// A fake provider that returns different outputs on successive calls.
///
/// Used by tests that need to verify multi-iteration behavior (e.g., loop nodes
/// where iteration N produces a different result than iteration N-1).
final class CountingFakeProvider: AgentProviding, @unchecked Sendable {
    let name: String
    private let outputs: [String]
    private(set) var callCount = 0

    init(name: String, outputs: [String]) {
        self.name = name
        self.outputs = outputs
    }

    func execute(prompt: String, context: TaskContext, timeout: Int? = nil, parameters: [String: String] = [:]) async throws -> TaskOutput {
        let output = callCount < outputs.count ? outputs[callCount] : outputs.last ?? ""
        callCount += 1
        return TaskOutput(output: output, exitStatus: 0)
    }

    func executeInteractive(prompt: String, context: TaskContext, sessionName: String, timeout: Int? = nil) async throws -> TaskOutput {
        TaskOutput(output: "", exitStatus: 0)
    }
}
