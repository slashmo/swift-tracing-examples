// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "customer",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "Serve", targets: ["Serve"]),
    ],
    dependencies: [
        .package(
            name: "swift-context",
            url: "https://github.com/slashmo/gsoc-swift-baggage-context.git",
            from: "0.5.0"
        ),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/slashmo/swift-nio.git", .branch("feature/baggage-context")),
        .package(url: "https://github.com/slashmo/gsoc-swift-tracing.git", .branch("main")),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "1.0.0-alpha.5"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.0.0"),
        .package(url: "https://github.com/MrLotU/SwiftPrometheus.git", from: "1.0.0-alpha.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.3.1"),
        .package(url: "https://github.com/slashmo/jaeger-client-swift.git", .branch("main")),
    ],
    targets: [
        .target(name: "Admin", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
        ]),
        .target(name: "API", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "BaggageContext", package: "swift-context"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "Tracing", package: "gsoc-swift-tracing"),
            .product(name: "NIOInstrumentation", package: "gsoc-swift-tracing"),
            .product(name: "OpenTelemetryInstrumentationSupport", package: "gsoc-swift-tracing"),
        ]),
        .target(name: "Serve", dependencies: [
            .target(name: "Admin"),
            .target(name: "API"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "BaggageContext", package: "swift-context"),
            .product(name: "Lifecycle", package: "swift-service-lifecycle"),
            .product(name: "LifecycleNIOCompat", package: "swift-service-lifecycle"),
            .product(name: "Jaeger", package: "jaeger-client-swift"),
            .product(name: "ZipkinReporting", package: "jaeger-client-swift"),
        ]),
    ]
)
