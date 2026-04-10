import GRDB

/// Handles schema migrations for the Orc SQLite database.
/// Each migration is a numbered step registered with GRDB's DatabaseMigrator,
/// which tracks applied migrations internally (no manual schema_version table needed).
internal struct MigrationManager {
    static func migrate(_ dbWriter: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // runs table — one row per workflow execution
            try db.create(table: "runs") { t in
                t.primaryKey("id", .text)
                t.column("workflow_name", .text).notNull()
                t.column("workflow_file", .text).notNull()
                t.column("status", .text).notNull()
                t.column("workspace_path", .text).notNull()
                t.column("inputs", .text)                           // JSON-encoded [String: String]?
                t.column("output", .text)
                t.column("cleanup_policy", .text).notNull().defaults(to: "30d")
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // node_executions table — one row per node attempt within a run
            try db.create(table: "node_executions") { t in
                t.primaryKey("id", .text)
                t.column("run_id", .text).notNull().references("runs", onDelete: .cascade)
                t.column("node_id", .text).notNull()
                t.column("status", .text).notNull()
                t.column("agent", .text)
                t.column("attempt", .integer).notNull().defaults(to: 1)
                t.column("iteration", .integer).notNull().defaults(to: 1)
                t.column("prompt", .text)
                t.column("message", .text)
                t.column("output", .text)
                t.column("error", .text)
                t.column("tmux_session", .text)
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
            }

            // logs table — maps node executions to log files on disk
            try db.create(table: "logs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("node_execution_id", .text).notNull().references("node_executions", onDelete: .cascade)
                t.column("stream", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("timestamp", .datetime).notNull()
            }

            // stats table — aggregated run statistics (never purged)
            try db.create(table: "stats") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("run_id", .text).notNull()
                t.column("workflow_name", .text).notNull()
                t.column("status", .text).notNull()
                t.column("node_count", .integer).notNull()
                t.column("duration_seconds", .double)
                t.column("completed_at", .datetime).notNull()
            }
        }

        do {
            try migrator.migrate(dbWriter)
        } catch {
            throw StoreError.migrationFailed(version: 1, detail: error.localizedDescription)
        }
    }
}
