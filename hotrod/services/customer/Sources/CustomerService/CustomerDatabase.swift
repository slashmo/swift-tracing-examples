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
import BaggageContext
import Instrumentation
import Tracing
import Vapor

final class CustomerDatabase {
    func findCustomer(byID id: String, context: DatabaseContext) -> EventLoopFuture<Customer> {
        let promise = context.eventLoop.makePromise(of: Customer.self)

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let span = InstrumentationSystem.tracer.startSpan(named: "SQL SELECT", baggage: context.baggage, ofKind: .client)

            // TODO: Add SQL semantics to OpenTelemetryInstrumentationSystem
            span.attributes["sql.query"] = "SELECT * FROM customer WHERE customer_id=\(id)"

            // simulate SQL call
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                if let customer = Customer.allCases.first(where: { $0.id == id }) {
                    promise.succeed(customer)
                } else {
                    let error = Abort(.notFound, reason: "No customer exists with the given ID.")
                    span.recordError(error)
                    promise.fail(error)
                }
                span.end()
            }
        }

        return promise.futureResult
    }
}

extension CustomerDatabase {
    struct DatabaseContext {
        private var _logger: Logger

        let eventLoop: EventLoop
        var baggage: Baggage

        init(request: Request, baggage: Baggage) {
            self.eventLoop = request.eventLoop
            self._logger = request.logger
            self.baggage = baggage
        }
    }
}

extension CustomerDatabase.DatabaseContext: BaggageContext {
    var logger: Logger {
        get {
            self._logger.with(self.baggage)
        }
        set(newValue) {
            self._logger = newValue.with(self.baggage)
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
