public enum ServerError: Error, Sendable {
    case bindFailed(host: String, port: Int, underlying: any Error)
    case portInUse(port: Int)
    case logFileNotFound(path: String)
    case engineError(String)
}
