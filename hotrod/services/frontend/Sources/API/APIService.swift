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

import struct Foundation.URLComponents
import Instrumentation
import Logging
import NIO
import NIOHTTP1
import NIOInstrumentation
import Tracing

public final class APIService {
    private let eventLoopGroup: EventLoopGroup
    private let fileIO: NonBlockingFileIO
    private let host: String
    private let port: UInt
    private let htdocsPath = "./Public"

    private let logger = Logger(label: "Frontend/API")

    public init(eventLoopGroup: EventLoopGroup, fileIO: NonBlockingFileIO, host: String, port: UInt) {
        self.eventLoopGroup = eventLoopGroup
        self.fileIO = fileIO
        self.host = host
        self.port = port
    }

    public func start() -> EventLoopFuture<Void> {
        self.bootstrapChannel(group: self.eventLoopGroup)
            .map { channel in
                self.logger.info(#"Server listing on \#(channel.localAddress!)"#)
            }
    }
}

// MARK: - Bootstrap Channel

extension APIService {
    private func bootstrapChannel(group: EventLoopGroup) -> EventLoopFuture<Channel> {
        ServerBootstrap(group: self.eventLoopGroup)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandlers(
                        HeaderExtractingHTTPServerHandler(),
                        HTTPServerHandler(responder: self.respond, logger: self.logger)
                    )
                }
            }

            // Enable SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

            // Bind the server to the specified address
            .bind(host: self.host, port: Int(self.port))
    }

    private func respond(request: Request, context: ChannelHandlerContext) -> EventLoopFuture<HTTPResponseHead> {
        if request.urlComponents.path == "/dispatch" {
            return self.dispatchDriver(request: request, context: context)
        }
        let path = self.htdocsPath + (request.urlComponents.path == "/" ? "/index.html" : request.urlComponents.path)
        return self.serveFile(path: path, version: request.head.version, context: context)
    }
}

// MARK: - Dispatch Driver

extension APIService {
    private func dispatchDriver(request: Request, context: ChannelHandlerContext) -> EventLoopFuture<HTTPResponseHead> {
        guard let customerID = request.urlComponents.queryItems?.first(where: { $0.name == "customer" })?.value else {
            let responseHead = HTTPResponseHead(version: request.head.version, status: .badRequest)
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            return context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).map { responseHead }
        }
        self.logger.info("Finding nearest driver for customer: \(customerID)")

        let clientSpan = InstrumentationSystem.tracer.startSpan(
            named: "GET /customer",
            baggage: request.baggage,
            ofKind: .client
        )
        clientSpan.attributes.http.method = HTTPMethod.GET.rawValue
        clientSpan.attributes.http.scheme = "http"
        clientSpan.attributes.http.target = "/customer"

        clientSpan.addLink(SpanLink(baggage: request.baggage))

        return context.eventLoop.flatScheduleTask(in: .seconds(1)) {
            let buffer = context.channel.allocator.buffer(string: #"{"Driver":"🐢","ETA":50000000000}"#)
            let responseHead = HTTPResponseHead(version: request.head.version, status: .ok, headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(buffer.readableBytes)",
            ])
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            clientSpan.attributes.http.statusCode = Int(HTTPResponseStatus.ok.code)
            clientSpan.attributes.http.statusText = HTTPResponseStatus.ok.reasonPhrase
            clientSpan.end()
            return context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).map { responseHead }
        }.futureResult
    }
}

// MARK: - Serve File

extension APIService {
    private func serveFile(
        path: String,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<HTTPResponseHead> {
        guard !path.containsDotDot() else {
            let responseHead = HTTPResponseHead(version: version, status: .forbidden)
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            return context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).map { responseHead }
        }

        let fileHandleAndRegion = self.fileIO.openFile(path: path, eventLoop: context.eventLoop)
        return fileHandleAndRegion
            .flatMap { file, region in
                self.fileIO
                    .readFileSize(fileHandle: file, eventLoop: context.eventLoop)
                    .map { size in
                        let headers: HTTPHeaders = ["Content-Length": "\(size)"]
                        let responseHead = HTTPResponseHead(version: version, status: .ok, headers: headers)
                        context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                        return responseHead
                    }
                    .flatMap { (responseHead: HTTPResponseHead) in
                        self.fileIO.readChunked(
                            fileRegion: region,
                            chunkSize: 32 * 1024,
                            allocator: context.channel.allocator,
                            eventLoop: context.eventLoop,
                            chunkHandler: { buffer in
                                context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))))
                            }
                        ).map { responseHead }
                    }
                    .flatMap { responseHead in
                        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).map { responseHead }
                    }
                    .flatMapThrowing { responseHead in
                        try file.close()
                        return responseHead
                    }
            }
    }
}
