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
import NIO
import NIOHTTP1
import NIOInstrumentation

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

    private func respond(head: HTTPRequestHead, context: ChannelHandlerContext) -> EventLoopFuture<HTTPResponseHead> {
        let path = self.htdocsPath + (head.uri == "/" ? "/index.html" : head.uri)
        return self.serveFile(path: path, version: head.version, context: context)
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
