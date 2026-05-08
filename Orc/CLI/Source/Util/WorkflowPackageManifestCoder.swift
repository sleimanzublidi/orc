import Foundation
import Yams

/// Reads and writes `manifest.yaml` for `.orc-workflow` packages.
enum WorkflowPackageManifestCoder {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidYAML(String)
        case missingField(String)
        case wrongFieldType(String)

        var description: String {
            switch self {
            case .invalidYAML(let detail):
                return "manifest.yaml is not valid YAML: \(detail)"
            case .missingField(let name):
                return "manifest.yaml is missing required field '\(name)'"
            case .wrongFieldType(let name):
                return "manifest.yaml field '\(name)' has the wrong type"
            }
        }
    }

    // MARK: - Encoding

    /// Serializes a manifest to a stable, human-readable YAML string.
    /// Field order is fixed so packages are diffable across runs.
    static func encode(_ manifest: WorkflowPackageManifest) -> String {
        var lines: [String] = []
        lines.append("name: \(yamlScalar(manifest.name))")
        lines.append("version: \(yamlScalar(manifest.version))")
        if let description = manifest.description {
            lines.append("description: \(yamlScalar(description))")
        }
        if let author = manifest.author {
            lines.append("author: \(yamlScalar(author))")
        }
        if let minVersion = manifest.minOrcVersion {
            lines.append("min_orc_version: \(yamlScalar(minVersion))")
        }
        lines.append("entrypoint: \(yamlScalar(manifest.entrypoint))")
        lines.append("files:")
        for path in manifest.files {
            lines.append("  - \(yamlScalar(path))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Decoding

    /// Parses a manifest from YAML source. Throws `Error` on malformed input or
    /// missing required fields.
    static func decode(_ yamlString: String) throws -> WorkflowPackageManifest {
        let parsed: Any?
        do {
            parsed = try Yams.load(yaml: yamlString)
        } catch {
            throw Error.invalidYAML(String(describing: error))
        }
        guard let dict = parsed as? [String: Any] else {
            throw Error.invalidYAML("top level must be a mapping")
        }

        let name = try requiredString(dict, key: "name")
        let version = try requiredString(dict, key: "version")
        let entrypoint = try requiredString(dict, key: "entrypoint")

        let description = try optionalString(dict, key: "description")
        let author = try optionalString(dict, key: "author")
        let minVersion = try optionalString(dict, key: "min_orc_version")

        guard let filesRaw = dict["files"] else {
            throw Error.missingField("files")
        }
        guard let filesArray = filesRaw as? [Any] else {
            throw Error.wrongFieldType("files")
        }
        var files: [String] = []
        for entry in filesArray {
            guard let path = entry as? String else {
                throw Error.wrongFieldType("files")
            }
            files.append(path)
        }

        return WorkflowPackageManifest(
            name: name,
            version: version,
            description: description,
            author: author,
            minOrcVersion: minVersion,
            entrypoint: entrypoint,
            files: files
        )
    }

    // MARK: - Helpers

    private static func requiredString(_ dict: [String: Any], key: String) throws -> String {
        guard let raw = dict[key] else {
            throw Error.missingField(key)
        }
        guard let value = raw as? String else {
            throw Error.wrongFieldType(key)
        }
        return value
    }

    private static func optionalString(_ dict: [String: Any], key: String) throws -> String? {
        guard let raw = dict[key] else { return nil }
        guard let value = raw as? String else {
            throw Error.wrongFieldType(key)
        }
        return value
    }

    /// Quotes a scalar when it would otherwise be ambiguous to a YAML parser.
    /// Uses double quotes and escapes embedded backslashes / quotes.
    private static func yamlScalar(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains(":")
            || value.contains("#")
            || value.contains("\n")
            || value.first == " "
            || value.last == " "
            || value.first == "-"
            || ["true", "false", "yes", "no", "null", "~"].contains(value.lowercased())
        if !needsQuoting {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
