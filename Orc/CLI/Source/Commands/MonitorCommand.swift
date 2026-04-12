import ArgumentParser
import Engine
import Server
import Foundation

struct MonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Start a local web server for monitoring workflow runs"
    )

    @Option(name: .long, help: "Port to bind (default: 9621)")
    var port: Int = 9621

    @Option(name: .long, help: "Host to bind (default: 127.0.0.1)")
    var host: String = "127.0.0.1"

    @Flag(name: .long, help: "Don't open browser automatically")
    var noOpen: Bool = false

    func run() async throws {
        let basePath = try OrcDirectory.require()
        let engine = try await WorkflowEngine(basePath: basePath)
        try await execute(engine: engine)
    }

    func execute(engine: some OrcEngineProviding) async throws {
        let server = MonitorServer(engine: engine, host: host, port: port)

        do {
            try await server.start()
        } catch {
            Format.printError("Error: Failed to start monitor server on \(host):\(port) — \(error)")
            throw ExitCode.failure
        }

        let url = server.url
        print("orc monitor running at \(url.absoluteString)")
        print("Press Ctrl+C to stop")

        if !noOpen {
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            try? process.run()
            #elseif os(Linux)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
            process.arguments = [url.absoluteString]
            try? process.run()
            #endif
        }

        // Block until cancelled (Ctrl+C)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler {
                signalSource.cancel()
                continuation.resume()
            }
            signalSource.resume()
        }

        await server.stop()
        print("\norc monitor stopped")
    }
}
