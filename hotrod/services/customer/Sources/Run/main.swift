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

import CustomerService
import Foundation
import Instrumentation
import Jaeger
import NIO
import Tracing
import ZipkinRecordingStrategy

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

do {
    let settings = JaegerTracer.Settings(
        serviceName: "customer",
        recordingStrategy: .zipkin(
            collectorURL: "http://localhost:9411",
            serviceName: "customer",
            eventLoopGroup: eventLoopGroup
        )
    )
    InstrumentationSystem.bootstrap(JaegerTracer(settings: settings, group: eventLoopGroup))
}

let service = try CustomerService(group: eventLoopGroup)

defer { service.shutdown() }
try service.start()
