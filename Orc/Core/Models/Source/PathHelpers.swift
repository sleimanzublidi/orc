import Foundation

// MARK: - Cross-Platform Path Helpers

/// URL-based path operations that avoid the NSString bridge, which has
/// historical edge-case differences on Linux (trailing slashes, empty strings).
extension String {
    /// Appends a path component using URL-based resolution.
    public func appendingPathComponent(_ component: String) -> String {
        URL(fileURLWithPath: self).appendingPathComponent(component).path
    }

    /// Returns the parent directory path.
    public var deletingLastPathComponent: String {
        URL(fileURLWithPath: self).deletingLastPathComponent().path
    }

    /// Returns the last path component (file name).
    public var lastPathComponent: String {
        URL(fileURLWithPath: self).lastPathComponent
    }

    /// Returns the path extension.
    public var pathExtension: String {
        URL(fileURLWithPath: self).pathExtension
    }

    /// Returns whether the path is absolute.
    public var isAbsolutePath: Bool {
        hasPrefix("/")
    }
}
