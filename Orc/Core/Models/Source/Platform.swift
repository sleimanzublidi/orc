// MARK: - Platform Defaults

/// Platform-specific constants for cross-platform support.
public enum Platform {
    /// The default shell path for the current platform.
    /// macOS uses `/bin/zsh`; Linux and other platforms fall back to `/bin/sh`.
    #if os(macOS)
    public static let defaultShell = "/bin/zsh"
    #else
    public static let defaultShell = "/bin/sh"
    #endif
}
