import Models

/// Short-lived container holding resolved (typed) config values for a node.
///
/// Created by resolving all `Resolvable` fields on a `Node` against the current
/// `TaskContext` before dispatching execution. This avoids repeated `.literalValue`
/// lookups and ensures template expressions are resolved exactly once per node.
struct ResolvedNodeConfig: Sendable {
    let agent: String?
    let timeoutSeconds: Int?
    let onFailure: FailureStrategy
    let workspaceMode: WorkspaceMode?
    let permissionMode: PermissionMode?
    let retry: ResolvedRetryConfig?
    let loop: ResolvedLoopConfig?
}

/// Resolved retry configuration with concrete typed values.
struct ResolvedRetryConfig: Sendable {
    let maxAttempts: Int
    let delaySeconds: Int
}

/// Resolved loop configuration with concrete typed values.
struct ResolvedLoopConfig: Sendable {
    let until: String
    let maxIterations: Int
    let freshContext: Bool
}
