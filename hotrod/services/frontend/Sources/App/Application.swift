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

import Logging
import NIO
import NIOInstrumentation

public final class Application {
    private let eventLoopGroup: EventLoopGroup
    private let host: String
    private let port: UInt

    private let logger: Logger

    public init(eventLoopGroup: EventLoopGroup, host: String, port: UInt, logger: Logger) {
        self.eventLoopGroup = eventLoopGroup
        self.host = host
        self.port = port
        self.logger = logger
    }

    public func start() -> EventLoopFuture<Void> {
        ServerBootstrap(group: self.eventLoopGroup)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandlers(
                        HeaderExtractingHTTPServerHandler(),
                        HTTPServerHandler(logger: self.logger)
                    )
                }
            }

            // Enable SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

            // Bind the server to the specified address
            .bind(host: self.host, port: Int(self.port)).map { _ in () }
            .always { result in
                guard case .success = result else { return }
                self.logger.info(#"Server listing on \#(self.host):\#(self.port)"#)
            }
    }
}
