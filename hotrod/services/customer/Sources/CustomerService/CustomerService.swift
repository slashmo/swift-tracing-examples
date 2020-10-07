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
import Instrumentation
import NIOInstrumentation
import Vapor

public struct CustomerService {
    private let app: Application

    public init(group: EventLoopGroup) throws {
        self.app = try Application(.detect(), .shared(group))
    }

    public func start() throws {
        try self.configure()
        try self.app.run()
    }

    public func shutdown() {
        self.app.shutdown()
    }

    private func configure() throws {
        try self.registerRoutes()
    }

    private func registerRoutes() throws {
        try self.app.routes.register(collection: CustomerController())
    }
}
