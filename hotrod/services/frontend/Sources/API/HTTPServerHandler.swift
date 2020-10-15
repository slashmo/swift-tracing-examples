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

import Baggage
import Dispatch
import struct Foundation.URLComponents
import Instrumentation
import Logging
import Metrics
import NIO
import NIOHTTP1
import OpenTelemetryInstrumentationSupport
import Tracing

typealias Responder = (Request, ChannelHandlerContext) -> EventLoopFuture<HTTPResponseHead>

final class HTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responder: Responder
    private let logger: Logger
    private var state = State.idle

    init(responder: @escaping Responder, logger: Logger) {
        self.responder = responder
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let requestHead):
            let urlComponents = URLComponents(string: requestHead.uri)!
            let operationName = "\(requestHead.method.rawValue) \(urlComponents.path)"
            self.logger.info("\(operationName)")
            let span = InstrumentationSystem.tracer.startSpan(
                named: operationName,
                baggage: context.baggage,
                ofKind: .server
            )
            let request = Request(head: requestHead, urlComponents: urlComponents, baggage: span.baggage)
            self.receiveRequest(request, span: span, context: context)
        case .body(let byteBuffer):
            guard case .waitingForRequestBody(_, _, let span) = self.state else {
                context.close(promise: nil)
                return
            }
            span.attributes.http.requestContentLength = byteBuffer.readableBytes
        case .end:
            context.fireChannelReadComplete()
            self.state.requestComplete()
            guard case .sendingResponse(let request, let start, let span) = self.state else {
                context.close(promise: nil)
                return
            }
            self.handleRequest(request, startedAt: start, span: span, context: context)
        }
    }

    private func receiveRequest(_ request: Request, span: Span, context: ChannelHandlerContext) {
        span.attributes.http.method = request.head.method.rawValue
        span.attributes.http.flavor = "\(request.head.version.major).\(request.head.version.minor)"
        span.attributes.http.target = request.urlComponents.path
        span.attributes.http.serverRoute = request.urlComponents.path
        span.attributes.http.serverClientIP = context.remoteAddress?.ipAddress
        span.attributes.net.peerIP = context.remoteAddress?.ipAddress
        span.attributes.http.userAgent = request.head.headers.first(name: "User-Agent")
        if let localAddress = context.localAddress, let port = localAddress.port {
            span.attributes.net.hostPort = port
            if let host = localAddress.ipAddress {
                span.attributes.http.host = "\(host):\(port)"
                span.attributes.http.serverName = host
            }
        }
        self.state.requestReceived(request, span: span)
    }

    private func handleRequest(
        _ request: Request,
        startedAt startTime: DispatchTime,
        span: Span,
        context: ChannelHandlerContext
    ) {
        self.responder(request, context)
            .flatMapError { error in
                span.recordError(error)
                let status: HTTPResponseStatus
                if let ioError = error as? IOError, ioError.errnoCode == 2 {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                let responseHead = HTTPResponseHead(version: request.head.version, status: status)
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                return context.writeAndFlush(self.wrapOutboundOut(.end(nil))).map { responseHead }
            }
            .always { result in
                guard case .success(let responseHead) = result else { return }
                self.endSpan(span, withResponse: responseHead)
                self.recordMetrics(forRequest: request, responseHead: responseHead, startTime: startTime)
            }
            .whenComplete { _ in
                if !request.head.isKeepAlive {
                    context.close(promise: nil)
                }
                self.state.responseComplete()
            }
    }

    private func endSpan(_ span: Span, withResponse responseHead: HTTPResponseHead) {
        span.attributes.http.statusCode = Int(responseHead.status.code)
        span.attributes.http.statusText = responseHead.status.reasonPhrase
        if let contentLength = responseHead.headers.first(name: "Content-Length").flatMap(Int.init) {
            span.attributes.http.responseContentLength = contentLength
        }
        span.end()
    }

    private func recordMetrics(
        forRequest request: Request,
        responseHead: HTTPResponseHead,
        startTime: DispatchTime
    ) {
        let dimensions = [
            ("method", request.head.method.rawValue),
            ("path", request.urlComponents.path),
            ("status", "\(responseHead.status.code)"),
        ]

        Counter(label: "http_requests_total", dimensions: dimensions).increment()

        Timer(
            label: "http_request_duration_seconds",
            dimensions: dimensions,
            preferredDisplayUnit: .seconds
        ).recordInterval(since: startTime)
    }
}

// MARK: - Request state machine

extension HTTPServerHandler {
    private enum State: Equatable {
        static func == (lhs: HTTPServerHandler.State, rhs: HTTPServerHandler.State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (
                .waitingForRequestBody(let lhsRequest, let lhsStart, _),
                .waitingForRequestBody(let rhsRequest, let rhsStart, _)
            ),
            (
                .sendingResponse(let lhsRequest, let lhsStart, _),
                .sendingResponse(let rhsRequest, let rhsStart, _)
            ):
                return lhsRequest == rhsRequest && lhsStart == rhsStart
            default:
                return false
            }
        }

        case idle
        case waitingForRequestBody(request: Request, start: DispatchTime, span: Span)
        case sendingResponse(request: Request, start: DispatchTime, span: Span)

        mutating func requestReceived(_ request: Request, span: Span) {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody(request: request, start: .now(), span: span)
        }

        mutating func requestComplete() {
            guard case .waitingForRequestBody(let request, let start, let span) = self else {
                preconditionFailure("Invalid state for request complete: \(self)")
            }
            self = .sendingResponse(request: request, start: start, span: span)
        }

        mutating func responseComplete() {
            guard case .sendingResponse = self else {
                preconditionFailure("Invalid state for response complete: \(self)")
            }
            self = .idle
        }
    }
}

struct Request: Equatable {
    let head: HTTPRequestHead
    let urlComponents: URLComponents
    let baggage: Baggage

    static func == (lhs: Request, rhs: Request) -> Bool {
        lhs.head == rhs.head
    }
}
