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
import Instrumentation
import Logging
import Metrics
import NIO
import NIOHTTP1
import OpenTelemetryInstrumentationSupport
import Tracing

typealias Responder = (HTTPRequestHead, ChannelHandlerContext) -> EventLoopFuture<HTTPResponseHead>

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
            self.receiveRequest(head: requestHead, context: context)
        case .body(let byteBuffer):
            guard case .waitingForRequestBody(_, _, let span) = self.state else {
                context.close(promise: nil)
                return
            }
            span.attributes.http.requestContentLength = byteBuffer.readableBytes
        case .end:
            context.fireChannelReadComplete()
            self.state.requestComplete()
            guard case .sendingResponse(let head, let start, let span) = self.state else {
                context.close(promise: nil)
                return
            }
            self.handleRequest(head, startedAt: start, span: span, context: context)
        }
    }

    private func receiveRequest(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let operationName = "\(head.method.rawValue) \(head.uri)"
        let span = InstrumentationSystem.tracer.startSpan(
            named: operationName,
            baggage: context.baggage,
            ofKind: .server
        )
        span.attributes.http.method = head.method.rawValue
        span.attributes.http.flavor = "\(head.version.major).\(head.version.minor)"
        span.attributes.http.target = head.uri
        span.attributes.http.serverRoute = head.uri
        span.attributes.http.serverClientIP = context.remoteAddress?.ipAddress
        span.attributes.net.peerIP = context.remoteAddress?.ipAddress
        span.attributes.http.userAgent = head.headers.first(name: "User-Agent")
        if let localAddress = context.localAddress, let port = localAddress.port {
            span.attributes.net.hostPort = port
            if let host = localAddress.ipAddress {
                span.attributes.http.host = "\(host):\(port)"
                span.attributes.http.serverName = host
            }
        }
        self.logger.info("\(operationName)")
        self.state.requestReceived(head, span: span)
    }

    private func handleRequest(
        _ requestHead: HTTPRequestHead,
        startedAt startTime: DispatchTime,
        span: Span,
        context: ChannelHandlerContext
    ) {
        self.responder(requestHead, context)
            .flatMapError { error in
                span.recordError(error)
                let status: HTTPResponseStatus
                if let ioError = error as? IOError, ioError.errnoCode == 2 {
                    status = .notFound
                } else {
                    status = .internalServerError
                }
                let responseHead = HTTPResponseHead(version: requestHead.version, status: status)
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                return context.writeAndFlush(self.wrapOutboundOut(.end(nil))).map { responseHead }
            }
            .always { result in
                guard case .success(let responseHead) = result else { return }
                self.endSpan(span, withResponse: responseHead)
                self.recordMetrics(forRequest: requestHead, responseHead: responseHead, startTime: startTime)
            }
            .whenComplete { _ in
                if !requestHead.isKeepAlive {
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
        forRequest requestHead: HTTPRequestHead,
        responseHead: HTTPResponseHead,
        startTime: DispatchTime
    ) {
        let dimensions = [
            ("method", requestHead.method.rawValue),
            ("path", requestHead.uri),
            ("status", "\(responseHead.status.code)"),
        ]

        Counter(label: "http_requests_total", dimensions: dimensions).increment()

        Timer(
            label: "http_request_duration_seconds",
            dimensions: dimensions,
            preferredDisplayUnit: .seconds
        ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
    }
}

// MARK: - Request state machine

extension HTTPServerHandler {
    private enum State: Equatable {
        static func == (lhs: HTTPServerHandler.State, rhs: HTTPServerHandler.State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (
                .waitingForRequestBody(let lhsHead, let lhsStart, _),
                .waitingForRequestBody(let rhsHead, let rhsStart, _)
            ),
            (
                .sendingResponse(let lhsHead, let lhsStart, _),
                .sendingResponse(let rhsHead, let rhsStart, _)
            ):
                return lhsHead == rhsHead && lhsStart == rhsStart
            default:
                return false
            }
        }

        case idle
        case waitingForRequestBody(head: HTTPRequestHead, start: DispatchTime, span: Span)
        case sendingResponse(head: HTTPRequestHead, start: DispatchTime, span: Span)

        mutating func requestReceived(_ requestHead: HTTPRequestHead, span: Span) {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody(head: requestHead, start: .now(), span: span)
        }

        mutating func requestComplete() {
            guard case .waitingForRequestBody(let head, let start, let span) = self else {
                preconditionFailure("Invalid state for request complete: \(self)")
            }
            self = .sendingResponse(head: head, start: start, span: span)
        }

        mutating func responseComplete() {
            guard case .sendingResponse = self else {
                preconditionFailure("Invalid state for response complete: \(self)")
            }
            self = .idle
        }
    }
}
