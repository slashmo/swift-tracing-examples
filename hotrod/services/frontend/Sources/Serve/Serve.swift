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
import Instrumentation
import Jaeger
import Lifecycle
import LifecycleNIOCompat
import Logging
import NIO
import ZipkinReporting

struct Serve: ParsableCommand {
    @Option(name: .long, help: "The host which to run on")
    var host = "localhost"

    @Option(name: .long, help: "The port on which the public API should be exposed")
    var port: UInt = 8080

    @Option(name: .long, help: "The port on which the admin API should be exposed")
    var adminPort: UInt = 8081

    @Option(name: .long, help: "The mininum log level")
    var logLevel: String = "info"

    @Option(name: .customLong("tracing.jaeger-host"), help: "The host of the Jaeger tracer")
    var jaegerHost: String?

    @Option(
        name: .customLong("tracing.zipkin-collector-port"),
        help: "The port where the Zipkin collector is exposed on"
    )
    var zipkinCollectorPort: UInt?

    func run() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        self.bootstrapLoggingSystem()
        self.bootstrapInstrumentationSystem(group: eventLoopGroup)

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

    private func bootstrapInstrumentationSystem(group: EventLoopGroup) {
        guard let jaegerHost = self.jaegerHost, let zipkinCollectorPort = self.zipkinCollectorPort else { return }
        let zipkinReporter = JaegerTracer.Reporter.zipkinv2(
            collectorHost: jaegerHost,
            collectorPort: zipkinCollectorPort,
            userAgent: "Fronted Service Tracing / Zipkin Reporter",
            eventLoopGroup: group
        )
        let jaegerSettings = JaegerTracer.Settings(serviceName: "frontend", reporter: zipkinReporter)
        InstrumentationSystem.bootstrap(JaegerTracer(settings: jaegerSettings, group: group))
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
