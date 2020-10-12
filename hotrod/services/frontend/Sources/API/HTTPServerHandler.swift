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
            guard case .waitingForRequestBody(_, _, let span) = self.state else { return }
            span.attributes.http.requestContentLength = byteBuffer.readableBytes
        case .end:
            context.fireChannelReadComplete()
            self.state.requestComplete()
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
        self.logger.info("\(operationName)")
        self.state.requestReceived(head, span: span)
    }

    private func completeResponse(context: ChannelHandlerContext) {
        guard case .sendingResponse(let requestHead, let start, let span) = self.state else { return }

        let responseStatus = HTTPResponseStatus.ok

        let messageBuffer = context.channel.allocator.buffer(staticString: "Hello\n")
        let responseHead = HTTPResponseHead(version: requestHead.version, status: responseStatus, headers: [
            "Content-Type": "text/plain",
            "Content-Length": "\(messageBuffer.readableBytes)",
        ])

        span.attributes.http.statusCode = Int(responseStatus.code)
        span.attributes.http.statusText = responseStatus.reasonPhrase
        span.attributes.http.responseContentLength = messageBuffer.readableBytes

        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(messageBuffer))), promise: nil)

        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { _ in
            span.end()

            let dimensions = [
                ("method", requestHead.method.rawValue),
                ("path", requestHead.uri),
                ("status", "\(responseStatus.code)"),
            ]

            Counter(label: "http_requests_total", dimensions: dimensions).increment()

            Timer(
                label: "http_request_duration_seconds",
                dimensions: dimensions,
                preferredDisplayUnit: .seconds
            ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)

            self.state.responseComplete(context: context, status: responseStatus)

            if !requestHead.isKeepAlive {
                context.close(promise: nil)
            }
        }
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: promise)
    }
}

extension HTTPServerHandler {
    private enum State: Equatable {
        static func == (lhs: HTTPServerHandler.State, rhs: HTTPServerHandler.State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.waitingForRequestBody(let lhsHead, let lhsStart, _), .waitingForRequestBody(let rhsHead, let rhsStart, _)),
                 let (.sendingResponse(lhsHead, lhsStart, _), .sendingResponse(rhsHead, rhsStart, _)):
                return lhsHead == rhsHead
                    && lhsStart == rhsStart
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

        mutating func responseComplete(context: ChannelHandlerContext, status: HTTPResponseStatus) {
            guard case .sendingResponse = self else {
                preconditionFailure("Invalid state for response complete: \(self)")
            }
            self = .idle
        }
    }
}
