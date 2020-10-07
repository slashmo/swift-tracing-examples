//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Tracing Examples open source project
//
// Copyright (c) YEARS Moritz Lang and the Swift Tracing Examples project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import App
import ArgumentParser
import Baggage
import Instrumentation
import Lifecycle
import LifecycleNIOCompat
import Logging
import Metrics
import NIO
import Prometheus
import Tracing

struct Serve: ParsableCommand {
    @Option(name: .shortAndLong, help: "The host which to run on")
    var host = "localhost"

    @Option(name: .shortAndLong, help: "The port which to run on")
    var port: UInt = 8080

    @Option(name: .shortAndLong, help: "The mininum log level")
    var logLevel: String = "info"

    func run() throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            if let logLevel = Logger.Level(rawValue: self.logLevel) {
                handler.logLevel = logLevel
            }
            return handler
        }
        let logger = Logger(label: "frontend")

        MetricsSystem.bootstrap(PrometheusClient())

        InstrumentationSystem.bootstrap(LoggingTracer(logger: logger))

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let app = Application(eventLoopGroup: eventLoopGroup, host: self.host, port: self.port, logger: logger)

        let lifecycle = ServiceLifecycle()
        lifecycle.register(label: "frontend", start: .eventLoopFuture(app.start), shutdown: .none)

        MetricsSystem.collect = { promise in
            try MetricsSystem.prometheus().collect(into: promise)
        }

        do {
            try lifecycle.startAndWait()
        } catch {
            Serve.exit(withError: error)
        }
    }
}

Serve.main()

private final class LoggedSpan: Span {
    let operationName: String
    let startTimestamp: Timestamp
    let baggage: Baggage
    private var onEnd: (LoggedSpan) -> Void

    var attributes = SpanAttributes()
    private(set) var isRecording = false
    private(set) var endTimestamp: Timestamp?

    init(
        forOperation operationName: String,
        startTimestamp: Timestamp,
        baggage: Baggage,
        onEnd: @escaping (LoggedSpan) -> Void
    ) {
        self.operationName = operationName
        self.startTimestamp = startTimestamp
        self.baggage = baggage
        self.onEnd = onEnd
    }

    deinit {
        print("Span deinit")
    }

    func setStatus(_ status: SpanStatus) {}
    func addEvent(_ event: SpanEvent) {}
    func recordError(_ error: Error) {}
    func addLink(_ link: SpanLink) {}
    func end(at timestamp: Timestamp) {
        self.endTimestamp = timestamp
        self.onEnd(self)
    }
}

private final class LoggingTracer: Tracer {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func extract<Carrier, Extractor>(
        _ carrier: Carrier,
        into baggage: inout Baggage,
        using extractor: Extractor
    ) where Carrier == Extractor.Carrier, Extractor: ExtractorProtocol {
        print("Extracting")
    }

    func inject<Carrier, Injector>(
        _ baggage: Baggage,
        into carrier: inout Carrier,
        using injector: Injector
    ) where Carrier == Injector.Carrier, Injector: InjectorProtocol {
        print("Injecting")
    }

    func startSpan(
        named operationName: String,
        baggage: Baggage,
        ofKind kind: SpanKind,
        at timestamp: Timestamp
    ) -> Span {
        let span = LoggedSpan(forOperation: operationName, startTimestamp: timestamp, baggage: baggage) { span in
            let duration = Double(span.endTimestamp!.millisSinceEpoch - span.startTimestamp.millisSinceEpoch) / 1000.0
            self.logger.trace(#"Ended "\#(operationName)", took: \#(duration)s"#)
        }
        self.logger.trace(#"Started "\#(operationName)""#)
        return span
    }

    func forceFlush() {}
}
