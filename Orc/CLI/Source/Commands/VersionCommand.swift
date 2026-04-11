import ArgumentParser
import Foundation
import Models

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print version information"
    )

    func run() async throws {
        print("orc \(OrcInfo.formattedVersion)")
        #if swift(>=6.0)
        print("Swift 6.0+")
        #elseif swift(>=5.10)
        print("Swift 5.10+")
        #else
        print("Swift 5.x")
        #endif
        #if arch(arm64)
        print("Platform: macOS (arm64)")
        #elseif arch(x86_64)
        print("Platform: macOS (x86_64)")
        #else
        print("Platform: macOS")
        #endif
    }
}
