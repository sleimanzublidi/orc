import Foundation

/// Defines the on-disk layout and manifest schema for `.orc-workflow` packages.
///
/// A package is a zip archive with the following layout:
///
///     manifest.yaml          # Package metadata + file index
///     files/                 # Mirrors the .orc/ subtree
///       workflows/<name>.yaml
///       prompts/<name>.md
///       ...
///
/// The `files/` prefix lets us add sibling top-level entries later (e.g. `LICENSE`,
/// `README.md`) without colliding with a project's `.orc/` paths.
enum WorkflowPackage {
    /// Filename of the manifest inside the archive.
    static let manifestName = "manifest.yaml"

    /// Top-level directory inside the archive that mirrors `.orc/`.
    static let filesPrefix = "files"

    /// Recommended file extension for packages.
    static let fileExtension = "orc-workflow"
}

/// Manifest written to / read from `manifest.yaml` at the root of a package.
struct WorkflowPackageManifest: Equatable, Sendable {
    /// Package name. Conventionally matches the entrypoint workflow's `name:` field.
    var name: String

    /// Semver-style package version. Defaults to `0.0.0` when authoring tools omit it.
    var version: String

    /// Optional human-readable description.
    var description: String?

    /// Optional author string (free-form).
    var author: String?

    /// Minimum `orc` version required to install this package.
    var minOrcVersion: String?

    /// Path to the primary workflow YAML, relative to the package's `files/` root
    /// (e.g. `workflows/self-improve.yaml`).
    var entrypoint: String

    /// Every file shipped in the package, each path relative to `files/`.
    /// The entrypoint MUST appear in this list.
    var files: [String]
}
