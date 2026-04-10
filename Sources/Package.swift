// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "orc", targets: ["CLI"]),
        .library(name: "OrcEngine", targets: ["Engine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        // Models — leaf, no dependencies
        .target(
            name: "Models",
            path: "Core/Models/Source"
        ),
        .testTarget(
            name: "ModelsTests",
            dependencies: ["Models"],
            path: "Core/Models/Tests"
        ),

        // Template — depends on Models
        .target(
            name: "Template",
            dependencies: ["Models"],
            path: "Core/Template/Source"
        ),
        .testTarget(
            name: "TemplateTests",
            dependencies: ["Template"],
            path: "Core/Template/Tests"
        ),

        // Parser — depends on Models, Template, Yams
        .target(
            name: "Parser",
            dependencies: [
                "Models",
                "Template",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Core/Parser/Source"
        ),
        .testTarget(
            name: "ParserTests",
            dependencies: ["Parser"],
            path: "Core/Parser/Tests"
        ),

        // Store — depends on Models, GRDB
        .target(
            name: "Store",
            dependencies: [
                "Models",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Core/Store/Source"
        ),
        .testTarget(
            name: "StoreTests",
            dependencies: ["Store"],
            path: "Core/Store/Tests"
        ),

        // Providers — depends on Models, swift-log
        .target(
            name: "Providers",
            dependencies: [
                "Models",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Core/Providers/Source"
        ),
        .testTarget(
            name: "ProvidersTests",
            dependencies: ["Providers"],
            path: "Core/Providers/Tests"
        ),

        // Engine — depends on Providers, Store, Parser, Template, Yams, swift-log
        .target(
            name: "Engine",
            dependencies: [
                "Providers",
                "Store",
                "Parser",
                "Template",
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Core/Engine/Source"
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine"],
            path: "Core/Engine/Tests"
        ),

        // CLI — executable, depends on Engine + ArgumentParser
        .executableTarget(
            name: "CLI",
            dependencies: [
                "Engine",
                "Models",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "CLI/Source"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "CLI",
                "Engine",
                "Models",
            ],
            path: "CLI/Tests"
        ),
    ]
)
