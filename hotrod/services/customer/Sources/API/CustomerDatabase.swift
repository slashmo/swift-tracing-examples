//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Tracing Examples open source project
//
// Copyright (c) 2020 Moritz Lang and the Swift Tracing Examples project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import BaggageContext
import Instrumentation
import Tracing
import Vapor

final class CustomerDatabase {
    func findCustomer(byID id: String, context: Context) -> EventLoopFuture<Customer> {
        let span = InstrumentationSystem.tracer.startSpan(
            named: "SQL SELECT",
            baggage: context.baggage,
            ofKind: .client
        )
        span.addLink(SpanLink(baggage: context.baggage))
        context.logger.info("Query customer database")

        // TODO: Add SQL semantics to OpenTelemetryInstrumentationSystem
        span.attributes["sql.query"] = "SELECT * FROM customer WHERE customer_id=?"
        return context.eventLoopGroup.next().flatScheduleTask(in: .milliseconds(Int64.random(in: 100 ... 1000))) {
            defer { span.end() }
            if let customer = Customer.allCases.first(where: { $0.id == id }) {
                return context.eventLoopGroup.next().makeSucceededFuture(customer)
            } else {
                let error = Abort(.notFound, reason: "No customer exists with the given ID.")
                span.recordError(error)
                return context.eventLoopGroup.next().makeFailedFuture(error)
            }
        }.futureResult
    }
}

extension CustomerDatabase {
    struct Context: BaggageContext {
        private var _logger: Logger
        let eventLoopGroup: EventLoopGroup

        var baggage: Baggage {
            willSet {
                self._logger.updateMetadata(previous: self.baggage, latest: newValue)
            }
        }

        var logger: Logger {
            get {
                self._logger
            }
            set {
                self._logger = newValue
                self._logger.updateMetadata(previous: .topLevel, latest: self.baggage)
            }
        }

        init(eventLoopGroup: EventLoopGroup, logger: Logger, baggage: Baggage) {
            self.eventLoopGroup = eventLoopGroup
            self._logger = logger
            self._logger.updateMetadata(previous: .topLevel, latest: baggage)
            self.baggage = baggage
        }
    }
}

struct Customer: Content {
    let id: String
    let name: String
    let location: String
}

extension Customer: CaseIterable {
    static var allCases: [Customer] = [
        Customer(id: "123", name: "Rachel's Floral Designs", location: "115,277"),
        Customer(id: "456", name: "Amazing Coffee Roasters", location: "211,653"),
        Customer(id: "392", name: "Trom Chocolatier", location: "577,322"),
        Customer(id: "731", name: "Japanese Desserts", location: "728,326"),
    ]
}

extension Request {
    var customerDatabase: CustomerDatabase {
        CustomerDatabase()
    }
}
