import ArgumentParser
import Foundation

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print version information"
    )

    func run() async throws {
        print("orc \(OrcVersion.current)")
        #if swift(>=6.0)
        print("Swift 6.0+")
        #elseif swift(>=5.10)
        print("Swift 5.10+")
        #else
        print("Swift 5.x")
        #endif
        print("Platform: macOS (arm64/x86_64)")
    }
}
