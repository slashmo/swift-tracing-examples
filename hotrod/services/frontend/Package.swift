// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "FrontendService",
    products: [
        .library(name: "FrontendService", targets: ["FrontendService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/slashmo/swift-nio.git", .branch("feature/baggage-context")),
        .package(url: "https://github.com/slashmo/async-http-client.git", .branch("feature/instrumentation")),
        .package(url: "https://github.com/slashmo/gsoc-swift-tracing.git", .branch("main")),
        .package(name: "swift-baggage-context", url: "https://github.com/slashmo/gsoc-swift-baggage-context.git", from: "0.3.0"),
    ],
    targets: [
        .target(name: "FrontendService", dependencies: []),
        .target(name: "Run", dependencies: [
            .target(name: "FrontendService"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "Baggage", package: "swift-baggage-context"),
            .product(name: "Instrumentation", package: "gsoc-swift-tracing"),
            .product(name: "TracingInstrumentation", package: "gsoc-swift-tracing"),
        ]),
    ]
)
