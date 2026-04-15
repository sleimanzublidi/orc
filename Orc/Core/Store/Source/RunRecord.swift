import Foundation
import GRDB
import Models

// MARK: - GRDB conformance for Run

extension Run: TableRecord {
    public static let databaseTableName = "runs"
}

extension Run: FetchableRecord {
    public init(row: Row) {
        // Decode inputs from JSON string
        let inputsJSON: String? = row["inputs"]
        var decodedInputs: [String: String]?
        if let json = inputsJSON, let data = json.data(using: .utf8) {
            decodedInputs = try? JSONDecoder().decode([String: String].self, from: data)
        }

        // Decode cleanup_policy from string
        let policyString: String = row["cleanup_policy"]
        let policy: CleanupPolicy
        switch policyString {
        case "on_success":
            policy = .onSuccess
        case "always":
            policy = .always
        case "never":
            policy = .never
        default:
            // Parse duration format: "30d" -> .duration(days: 30)
            if policyString.hasSuffix("d"), let days = Int(policyString.dropLast()) {
                policy = .duration(days: days)
            } else {
                policy = .duration(days: 30)
            }
        }

        self.init(
            id: row["id"],
            workflowName: row["workflow_name"],
            workflowFile: row["workflow_file"],
            // Safe unwrap: fall back to .pending for unknown status values
            // rather than force-unwrapping, per project convention.
            status: {
                let raw: String = row["status"]
                return RunStatus(rawValue: raw) ?? .pending
            }(),
            workspacePath: row["workspace_path"],
            inputs: decodedInputs,
            output: row["output"],
            cleanupPolicy: policy,
            parentRunID: row["parent_run_id"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

extension Run: PersistableRecord {
    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["workflow_name"] = workflowName
        container["workflow_file"] = workflowFile
        container["status"] = status.rawValue
        container["workspace_path"] = workspacePath

        // Encode inputs as JSON string
        if let inputs = inputs, let data = try? JSONEncoder().encode(inputs) {
            container["inputs"] = String(data: data, encoding: .utf8)
        } else {
            container["inputs"] = nil as String?
        }

        container["output"] = output

        // Encode cleanup_policy as string
        let policyString: String
        switch cleanupPolicy {
        case .duration(let days):
            policyString = "\(days)d"
        case .onSuccess:
            policyString = "on_success"
        case .always:
            policyString = "always"
        case .never:
            policyString = "never"
        }
        container["cleanup_policy"] = policyString

        container["parent_run_id"] = parentRunID
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
}
