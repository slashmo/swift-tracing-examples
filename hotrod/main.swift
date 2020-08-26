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
import ArgumentParser
import Baggage
import CustomerService
import Instrumentation
import Lifecycle
import Logging
import TracingInstrumentation

struct HotRod: ParsableCommand {
    func run() throws {
        InstrumentationSystem.bootstrap(LoggingTracer())

        let lifecycle = ServiceLifecycle()
        let customerService = try CustomerService()

        lifecycle.register(
            label: "customer",
            start: .sync(customerService.start),
            shutdown: .sync(customerService.shutdown)
        )

        try lifecycle.startAndWait()
    }
}

HotRod.main()

// MARK: - Tracer -

final class LoggingTracer: TracingInstrument {
    private let logger = Logger(label: "LoggingTracer")

    func extract<Carrier, Extractor>(
        _ carrier: Carrier,
        into context: inout BaggageContext,
        using extractor: Extractor
    )
        where
        Carrier == Extractor.Carrier, Extractor: ExtractorProtocol {
        if let traceID = extractor.extract(key: "x-trace-id", from: carrier) {
            context.traceID = traceID
        }
    }

    func inject<Carrier, Injector>(
        _ context: BaggageContext,
        into carrier: inout Carrier,
        using injector: Injector
    )
        where
        Carrier == Injector.Carrier, Injector: InjectorProtocol {
        let traceID = context.traceID ?? "12345678-1234-1234-1234-123456789012"
        injector.inject(traceID, forKey: "x-trace-id", into: &carrier)
    }

    func forceFlush() {}

    func startSpan(
        named operationName: String,
        context: BaggageContextCarrier,
        ofKind kind: SpanKind,
        at timestamp: Timestamp
    ) -> Span {
        self.logger.with(context: context.baggage).info(#"Starting span "\#(operationName)""#)
        return LoggingSpan(operationName: operationName, logger: self.logger, context: context.baggage)
    }

    final class LoggingSpan: Span {
        let context: BaggageContext
        var attributes: SpanAttributes = [:]
        private(set) var isRecording = false
        private let operationName: String
        private let logger: Logger

        init(operationName: String, logger: Logger, context: BaggageContext) {
            self.operationName = operationName
            self.logger = logger
            self.context = context
        }

        func setStatus(_ status: SpanStatus) {}

        func addEvent(_ event: SpanEvent) {}

        func recordError(_ error: Error) {
            self.logger.with(context: self.context)
                .info(#"Recorded error in span "\#(self.operationName)": \#(error)"#)
        }

        func addLink(_ link: SpanLink) {}

        func end(at timestamp: Timestamp) {
            self.logger.with(context: self.context).info(#"Finished span "\#(self.operationName)""#)
            var attributesComponents = [String]()
            self.attributes.forEach { key, value in
                attributesComponents.append(#""\#(key)": \#(value)"#)
            }
            self.logger.with(context: self.context)
                .info("Recording attributes: [\(attributesComponents.joined(separator: ", "))]")
        }
    }
}

private enum TraceID: BaggageContextKey {
    typealias Value = String
}

extension BaggageContext {
    var traceID: String? {
        get {
            self[TraceID]
        }
        set {
            self[TraceID] = newValue
        }
    }
}
