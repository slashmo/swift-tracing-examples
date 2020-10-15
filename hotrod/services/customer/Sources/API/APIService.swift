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
import Vapor

public final class APIService {
    private let eventLoopGroup: EventLoopGroup
    private let host: String
    private let port: UInt

    private let logger = Logger(label: "Frontend/Customer")

    public init(eventLoopGroup: EventLoopGroup, host: String, port: UInt) {
        self.eventLoopGroup = eventLoopGroup
        self.host = host
        self.port = port
    }

    public func start() -> EventLoopFuture<Void> {
        do {
            try self.app().run()
            return self.eventLoopGroup.next().makeSucceededFuture(())
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    private func app() throws -> Application {
        var environment = try Environment.detect()
        // Vapor crashes on unknown flags so we need to remove everything but the first (executable).
        environment.arguments.removeLast(environment.arguments.count - 1)
        let app = Application(environment, .shared(self.eventLoopGroup))
        app.logger = self.logger
        app.http.server.configuration.port = Int(self.port)
        app.http.server.configuration.hostname = self.host
        try app.routes.register(collection: CustomerController())
        return app
    }
}
