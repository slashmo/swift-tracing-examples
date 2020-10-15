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

import Logging
import Metrics
import NIO
import NIOHTTP1
import Prometheus

public final class AdminService {
    private let eventLoopGroup: EventLoopGroup
    private let host: String
    private let port: UInt
    private let logger = Logger(label: "Customer/Admin")

    public init(eventLoopGroup: EventLoopGroup, host: String, port: UInt) {
        self.eventLoopGroup = eventLoopGroup
        self.host = host
        self.port = port
    }

    public func start() -> EventLoopFuture<Void> {
        MetricsSystem.bootstrap(PrometheusClient())

        return ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(MetricsHTTPServerHandler())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

            .bind(host: self.host, port: Int(self.port))
            .always { result in
                guard case .success(let channel) = result else { return }
                self.logger.info(#"Server listing on \#(channel.localAddress!)"#)
            }
            .map { _ in () }
    }
}

private final class MetricsHTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var state = State.idle

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let requestHead):
            self.state.requestReceived(requestHead)
        case .body:
            break
        case .end:
            let requestHead = self.state.requestComplete()
            switch requestHead.uri {
            case "/metrics":
                let promise = context.eventLoop.makePromise(of: Void.self)

                try! MetricsSystem.prometheus().collect { (byteBuffer: ByteBuffer) in
                    let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok, headers: [
                        "Content-Type": "text/plain",
                    ])
                    context.write(self.wrapOutboundOut(.head(responseHead)), promise: promise)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(byteBuffer))), promise: promise)
                    context.write(self.wrapOutboundOut(.end(nil)), promise: promise)
                    self.state.responseComplete()
                }
            default:
                let responseHead = HTTPResponseHead(version: requestHead.version, status: .notFound)
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                self.state.responseComplete()
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

extension MetricsHTTPServerHandler {
    private enum State: Equatable {
        case idle
        case waitingForRequestBody(HTTPRequestHead)
        case sendingResponse(HTTPRequestHead)

        mutating func requestReceived(_ requestHead: HTTPRequestHead) {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody(requestHead)
        }

        mutating func requestComplete() -> HTTPRequestHead {
            guard case .waitingForRequestBody(let requestHead) = self else {
                preconditionFailure("Invalid state for request complete: \(self)")
            }
            self = .sendingResponse(requestHead)
            return requestHead
        }

        mutating func responseComplete() {
            guard case .sendingResponse = self else {
                preconditionFailure("Invalid state for response complete: \(self)")
            }
            self = .idle
        }
    }
}
