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
import NIOInstrumentation
import OpenTelemetryInstrumentationSupport
import Tracing
import Vapor

final class CustomerController {
    // Wraps `getCustomer(_ request: Request)` to trace the request.
    // TODO: note that this code can be either done internally in vapor or other instrumentation layers in the future
    private func getCustomerTraced(_ request: Request) -> EventLoopFuture<Response> {
        var baggage = Baggage.topLevel
        InstrumentationSystem.instrument.extract(request.headers, into: &baggage, using: HTTPHeadersExtractor())

        let span = InstrumentationSystem.tracer.startSpan(
            named: "HTTP \(request.method) \(request.url.string)",
            baggage: baggage,
            ofKind: .server
        )
        span.attributes.http.method = request.method.rawValue
        span.attributes.http.flavor = "\(request.version.major).\(request.version.minor)"
        span.attributes.http.host = request.headers.host
        span.attributes.http.target = request.url.string
        span.attributes.http.scheme = request.url.scheme
        span.attributes.http.userAgent = request.headers.userAgent

        if let remoteAddress = request.remoteAddress {
            span.attributes.net.peerIP = remoteAddress.ipAddress
        }

        return self
            // pass along the span.context as it may contain additional values compared to context
            .getCustomer(request, baggage: span.baggage)
            .always { result in
                switch result {
                case .success(let response):
                    span.attributes.http.statusCode = Int(response.status.code)
                    span.attributes.http.statusText = response.status.reasonPhrase
                    span.attributes.http.responseContentLength = response.headers.contentLength
                case .failure(let error):
                    if let abort = error as? Abort {
                        span.attributes.http.statusCode = Int(abort.status.code)
                        span.attributes.http.statusText = abort.status.reasonPhrase
                    }
                    span.recordError(error)
                }
                span.end()
            }
    }

    private func getCustomer(_ request: Request, baggage: Baggage) -> EventLoopFuture<Response> {
        do {
            let customerID = try request.query.get(String.self, at: "customer")
            return CustomerDatabase()
                .findCustomer(byID: customerID, context: .init(request: request, baggage: baggage))
                .encodeResponse(status: .ok, for: request)
        } catch {
            return request.eventLoop.makeFailedFuture(Abort(.badRequest))
        }
    }
}

extension CustomerController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("customer", use: self.getCustomerTraced)
    }
}

private extension HTTPHeaders {
    var contentLength: Int? {
        self.first(name: .contentLength).flatMap(Int.init)
    }

    var userAgent: String? {
        self.first(name: .userAgent)
    }

    var host: String? {
        self.first(name: .host)
    }
}
