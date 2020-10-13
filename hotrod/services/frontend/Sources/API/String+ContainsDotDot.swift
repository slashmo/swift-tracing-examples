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

extension String {
    func containsDotDot() -> Bool {
        for idx in self.indices {
            if self[idx] == ".", idx < self.index(before: self.endIndex), self[self.index(after: idx)] == "." {
                return true
            }
        }
        return false
    }
}
