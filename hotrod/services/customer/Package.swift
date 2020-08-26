// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "customer",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "CustomerService", targets: ["CustomerService"]),
        .executable(name: "Run", targets: ["Run"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/slashmo/gsoc-swift-tracing.git", .branch("main")),
        .package(
            name: "swift-baggage-context",
            url: "https://github.com/slashmo/gsoc-swift-baggage-context.git",
            from: "0.3.0"
        ),
    ],
    targets: [
        .target(
            name: "CustomerService",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Instrumentation", package: "gsoc-swift-tracing"),
                .product(name: "NIOInstrumentation", package: "gsoc-swift-tracing"),
                .product(name: "TracingInstrumentation", package: "gsoc-swift-tracing"),
                .product(name: "Baggage", package: "swift-baggage-context"),
                .product(name: "BaggageLogging", package: "swift-baggage-context"),
            ]
        ),
        .target(name: "Run", dependencies: [.target(name: "CustomerService")]),
    ]
)
