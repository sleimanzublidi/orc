public enum OrcInfo {
    public static let version = "1.0.0"
    public static let githash = ""
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
