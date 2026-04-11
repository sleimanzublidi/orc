import Foundation

/// Errors specific to the Store persistence layer.
public enum StoreError: Error, Sendable, Equatable {
    case databaseNotFound(path: String)
    case migrationFailed(version: Int, detail: String)
    case recordNotFound(table: String, id: String)
    case writeFailure(detail: String)
    case internalError(detail: String)
}

extension StoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .databaseNotFound(let path):
            return "Database not found at '\(path)'."
        case .migrationFailed(let version, let detail):
            return "Migration v\(version) failed: \(detail)"
        case .recordNotFound(let table, let id):
            return "Record '\(id)' not found in '\(table)'."
        case .writeFailure(let detail):
            return "Write failed: \(detail)"
        case .internalError(let detail):
            return "Internal store error: \(detail)"
        }
    }
}

extension StoreError: LocalizedError {
    public var errorDescription: String? { description }
}
