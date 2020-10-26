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

private var fileExtensionContentTypeMap = [
    "html": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
]

extension String {
    var contentType: String? {
        for (fileExtension, contentType) in fileExtensionContentTypeMap {
            if self.hasSuffix(fileExtension) {
                return contentType
            }
        }
        return nil
    }
}
