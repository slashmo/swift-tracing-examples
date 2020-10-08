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

import Baggage
import Dispatch
import struct Foundation.UUID
import Instrumentation
import Logging
import Metrics
import NIO
import NIOHTTP1
import Tracing

extension MetricsSystem {
    public static var collect: (_ promise: EventLoopPromise<ByteBuffer>) throws -> Void = { _ in }
}

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
            let operationName = "\(requestHead.method.rawValue) \(requestHead.uri)"
            let span = InstrumentationSystem.tracer.startSpan(
                named: operationName,
                baggage: context.baggage,
                ofKind: .server
            )
            let request = Request(head: requestHead, span: span)
            self.logger.info("\(operationName)")
            self.state.requestReceived(request)
        case .body(let byteBuffer):
            print(byteBuffer)
        case .end:
            let request = self.state.requestComplete()
            context.fireChannelReadComplete()

            if request.head.uri == "/metrics" {
                do {
                    let promise = context.eventLoop.makePromise(of: ByteBuffer.self)
                    try MetricsSystem.collect(promise)
                    promise.futureResult.whenComplete { result in
                        switch result {
                        case .success(let buffer):
                            let responseHead = HTTPResponseHead(version: request.head.version, status: .ok, headers: [
                                "Content-Type": "text/plain",
                                "Content-Length": "\(buffer.readableBytes)",
                            ])
                            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            self.state.responseComplete(context: context, endData: self.wrapOutboundOut(.end(nil)))
                        case .failure(let error):
                            self.logger.error("\(error)")
                        }
                    }
                } catch {
                    print(error)
                }
            } else {
                let messageBuffer = context.channel.allocator.buffer(staticString: "Hello\n")
                let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok, headers: [
                    "Content-Type": "text/plain",
                    "Content-Length": "\(messageBuffer.readableBytes)",
                ])
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                context.write(self.wrapOutboundOut(.body(.byteBuffer(messageBuffer))), promise: nil)
                self.state.responseComplete(context: context, endData: self.wrapOutboundOut(.end(nil)))
            }
        }
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

            guard request.head.uri != "/metrics" else { return }
            Counter(
                label: "http_requests_total",
                dimensions: [
                    ("method", request.head.method.rawValue),
                    ("path", request.head.uri),
                    ("status", "\(HTTPResponseStatus.ok.code)"),
                ]
            ).increment()
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
            Timer(
                label: "http_request_duration_seconds",
                dimensions: [
                    ("method", request.head.method.rawValue),
                    ("path", request.head.uri),
                ],
                preferredDisplayUnit: .seconds
            ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - request.startTime.uptimeNanoseconds)
        }
    }
}

struct Request: Equatable, Identifiable {
    let id: String
    let startTime: DispatchTime
    let head: HTTPRequestHead
    let span: Span

    init(head: HTTPRequestHead, span: Span) {
        self.id = UUID().uuidString
        self.startTime = .now()
        self.head = head
        self.span = span
    }

    static func == (lhs: Request, rhs: Request) -> Bool {
        lhs.id == rhs.id
    }
}
