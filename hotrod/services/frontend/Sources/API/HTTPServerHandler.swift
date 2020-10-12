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

final class HTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger
    private var state = State.idle

    init(logger: Logger) {
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let requestHead):
            self.receiveRequest(head: requestHead, context: context)
        case .body(let byteBuffer):
            guard case .waitingForRequestBody(let request) = self.state else { return }
            request.span.attributes.http.requestContentLength = byteBuffer.readableBytes
        case .end:
            self.completeResponse(context: context)
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
        span.attributes.http.userAgent = head.headers.first(name: "user-agent")
        if let localAddress = context.localAddress, let port = localAddress.port {
            span.attributes.net.hostPort = port
            if let host = localAddress.ipAddress {
                span.attributes.http.host = "\(host):\(port)"
                span.attributes.http.serverName = host
            }
        }
        let request = Request(head: head, span: span)
        self.logger.info("\(operationName)")
        self.state.requestReceived(request)
    }

    private func completeResponse(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()

        let request = self.state.requestComplete()
        let responseStatus = HTTPResponseStatus.ok

        let messageBuffer = context.channel.allocator.buffer(staticString: "Hello\n")
        let responseHead = HTTPResponseHead(version: request.head.version, status: responseStatus, headers: [
            "Content-Type": "text/plain",
            "Content-Length": "\(messageBuffer.readableBytes)",
        ])

        request.span.attributes.http.statusCode = Int(responseStatus.code)
        request.span.attributes.http.statusText = responseStatus.reasonPhrase
        request.span.attributes.http.responseContentLength = messageBuffer.readableBytes

        self.recordMetrics(forRequest: request, respondedWith: responseStatus)

        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(messageBuffer))), promise: nil)
        self.state.responseComplete(context: context, endData: self.wrapOutboundOut(.end(nil)))
    }

    private func recordMetrics(forRequest request: Request, respondedWith status: HTTPResponseStatus) {
        let dimensions = [
            ("method", request.head.method.rawValue),
            ("path", request.head.uri),
            ("status", "\(status.code)"),
        ]

        Counter(label: "http_requests_total", dimensions: dimensions).increment()

        Timer(
            label: "http_request_duration_seconds",
            dimensions: dimensions,
            preferredDisplayUnit: .seconds
        ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - request.startTime.uptimeNanoseconds)
    }
}

extension HTTPServerHandler {
    private enum State: Equatable {
        case idle
        case waitingForRequestBody(Request)
        case sendingResponse(Request)

        mutating func requestReceived(_ request: Request) {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody(request)
        }

        mutating func requestComplete() -> Request {
            guard case .waitingForRequestBody(let request) = self else {
                preconditionFailure("Invalid state for request complete: \(self)")
            }
            self = .sendingResponse(request)
            return request
        }

        mutating func responseComplete(context: ChannelHandlerContext, endData: NIOAny) {
            guard case .sendingResponse(let request) = self else {
                preconditionFailure("Invalid state for response complete: \(self)")
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            if !request.head.isKeepAlive {
                promise.futureResult.whenComplete { _ in
                    context.close(promise: nil)
                }
            }
            context.writeAndFlush(endData, promise: promise)
            request.span.end()
            self = .idle
        }
    }
}
