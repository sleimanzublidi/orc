public enum OrcInfo {
    public static let version = "1.0.0"
    /// Injected by Scripts/build.sh at build time via sed; restored to empty on exit.
    public static let githash = ""
    /// Injected by Scripts/build.sh at build time via sed; restored to empty on exit.
    public static let buildTimestamp = ""

    public static var formattedVersion: String {
        var result = "v\(version)"
        if !githash.isEmpty {
            result += " (\(githash))"
        }
        if !buildTimestamp.isEmpty {
            result += " \(buildTimestamp)"
        }
        return result
    }
}
