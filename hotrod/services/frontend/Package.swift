// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "frontend",
    products: [
        .executable(name: "Frontend", targets: ["Run"]),
    ],
    dependencies: [
        .package(
            name: "swift-context",
            url: "https://github.com/slashmo/gsoc-swift-baggage-context.git",
            from: "0.5.0"
        ),
        .package(url: "https://github.com/slashmo/swift-nio.git", .branch("feature/baggage-context")),
        .package(url: "https://github.com/slashmo/gsoc-swift-tracing.git", .branch("main")),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "1.0.0-alpha.5"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.0.0"),
        .package(url: "https://github.com/MrLotU/SwiftPrometheus.git", from: "1.0.0-alpha.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.3.1"),
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "BaggageContext", package: "swift-context"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "Tracing", package: "gsoc-swift-tracing"),
            .product(name: "NIOInstrumentation", package: "gsoc-swift-tracing"),
        ]),
        .target(name: "Run", dependencies: [
            .target(name: "App"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "BaggageContext", package: "swift-context"),
            .product(name: "Lifecycle", package: "swift-service-lifecycle"),
            .product(name: "LifecycleNIOCompat", package: "swift-service-lifecycle"),
        ]),
    ]
)
