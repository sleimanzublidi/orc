import Foundation
import Models

/// Creates and manages workspace directories for workflow runs.
///
/// Each run gets its own workspace under `.orc/workspaces/<run-id>/` with
/// subdirectories for workspace files, artifacts, and logs.
public struct WorkspaceManager: Sendable {
    /// Path to the `.orc` directory.
    let basePath: String

    public init(basePath: String) {
        self.basePath = basePath
    }

    /// Creates the workspace directory structure for a run.
    ///
    /// - Parameter runID: The run ID to create a workspace for.
    /// - Returns: The path to the workspace root directory.
    /// - Throws: If directory creation fails.
    func createWorkspace(runID: String) throws -> String {
        let runDir = workspacePath(for: runID)
        let workDir = (runDir as NSString).appendingPathComponent("workspace")
        let artifactsDir = (runDir as NSString).appendingPathComponent("artifacts")
        let logsDir = (runDir as NSString).appendingPathComponent("logs")

        let fm = FileManager.default
        try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: artifactsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)

        return runDir
    }

    /// Cleans up a workspace directory based on the cleanup policy and run status.
    ///
    /// - Parameters:
    ///   - runID: The run ID whose workspace to clean up.
    ///   - policy: The cleanup policy to apply.
    ///   - runStatus: The final status of the run.
    func cleanupWorkspace(runID: String, policy: CleanupPolicy, runStatus: RunStatus) throws {
        let runDir = workspacePath(for: runID)

        switch policy {
        case .always:
            try removeWorkspace(at: runDir)

        case .onSuccess:
            if runStatus == .completed {
                try removeWorkspace(at: runDir)
            }

        case .duration:
            // Duration-based cleanup is handled by startupPurge, not at run completion.
            break

        case .never:
            break
        }
    }

    /// Returns whether the workspace directory exists for the given run.
    func workspaceExists(runID: String) -> Bool {
        let runDir = workspacePath(for: runID)
        return FileManager.default.fileExists(atPath: runDir)
    }

    /// Purges workspaces for runs that have exceeded their retention period.
    /// Called at startup to clean up old workspaces.
    ///
    /// Checks all runs (not just completed) so that failed and cancelled runs
    /// with duration-based cleanup are also purged once their retention period expires.
    ///
    /// - Parameter store: The workflow store to query for expired runs.
    func startupPurge(store: any WorkflowStoring) async throws {
        // Query all runs regardless of status and check each run's cleanup policy.
        let runs = try await store.listRuns(status: nil)
        let fm = FileManager.default

        for run in runs {
            if case .duration(let days) = run.cleanupPolicy {
                guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
                    continue
                }
                if run.updatedAt < cutoff {
                    let runDir = workspacePath(for: run.id)
                    if fm.fileExists(atPath: runDir) {
                        try? fm.removeItem(atPath: runDir)
                    }
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func workspacePath(for runID: String) -> String {
        (basePath as NSString)
            .appendingPathComponent("workspaces")
            .appending("/\(runID)")
    }

    private func removeWorkspace(at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }
}
