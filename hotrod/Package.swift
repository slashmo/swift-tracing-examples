// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "hotrod",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "hotrod", targets: ["HotRod"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.3.0"),

        // pull lifecycle from main branch where startAndWait() correctly handles shutdown
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", .branch("main")),

        .package(url: "https://github.com/slashmo/gsoc-swift-tracing.git", .branch("main")),
        .package(
            name: "swift-baggage-context",
            url: "https://github.com/slashmo/gsoc-swift-baggage-context.git",
            from: "0.3.0"
        ),
        .package(path: "./services/customer"),
    ],
    targets: [
        .target(
            name: "HotRod",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Lifecycle", package: "swift-service-lifecycle"),
                .product(name: "Instrumentation", package: "gsoc-swift-tracing"),
                .product(name: "Tracing", package: "gsoc-swift-tracing"),
                .product(name: "OpenTelemetryInstrumentationSupport", package: "gsoc-swift-tracing"),
                .product(name: "Baggage", package: "swift-baggage-context"),
                .product(name: "CustomerService", package: "customer"),
            ],
            path: ".",
            sources: ["main.swift"]
        ),
    ]
)
