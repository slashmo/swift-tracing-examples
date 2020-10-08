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

import Dispatch
import Instrumentation
import NIOHTTP1
import Tracing

struct Request: Equatable {
    let startTime: DispatchTime
    let head: HTTPRequestHead
    let span: Span

    init(head: HTTPRequestHead, span: Span) {
        self.startTime = .now()
        self.head = head
        self.span = span
    }

    static func == (lhs: Request, rhs: Request) -> Bool {
        lhs.startTime == rhs.startTime
            && lhs.head == rhs.head
    }
}
