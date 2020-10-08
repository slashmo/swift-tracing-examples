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

import Admin
import API
import ArgumentParser
import Lifecycle
import LifecycleNIOCompat
import Logging
import NIO

struct Serve: ParsableCommand {
    @Option(name: .long, help: "The host which to run on")
    var host = "localhost"

    @Option(name: .long, help: "The port on which the public API should be exposed")
    var port: UInt = 8080

    @Option(name: .long, help: "The port on which the admin API should be exposed")
    var adminPort: UInt = 8081

    @Option(name: .long, help: "The mininum log level")
    var logLevel: String = "info"

    func run() throws {
        self.bootstrapLoggingSystem()

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let lifecycle = self.serviceLifecycle(group: eventLoopGroup)

        try lifecycle.startAndWait()
    }

    private func bootstrapLoggingSystem() {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            if let logLevel = Logger.Level(rawValue: self.logLevel) {
                handler.logLevel = logLevel
            }
            return handler
        }
    }

    private func serviceLifecycle(group: EventLoopGroup) -> ServiceLifecycle {
        let admin = AdminService(eventLoopGroup: group, host: self.host, port: self.adminPort)
        let api = APIService(eventLoopGroup: group, host: self.host, port: self.port)

        let lifecycle = ServiceLifecycle()
        lifecycle.register(label: "admin", start: .eventLoopFuture(admin.start), shutdown: .none)
        lifecycle.register(label: "api", start: .eventLoopFuture(api.start), shutdown: .none)
        return lifecycle
    }
}
