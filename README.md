# Swift Tracing Examples

[![Swift 5.2](https://img.shields.io/badge/Swift-5.2-ED523F.svg?style=flat)](https://swift.org/download/)

> Examples illustrating how distributed systems (developed in Swift) may be instrumented, specifically using tracing.

It uses various libraries created as part of the Swift Tracing efforts happening in [this repository](https://github.com/slashmo/gsoc-swift-tracing).

## Examples

- [Hot R.O.D. - Rides on Demand](./hotrod): A *Swifty* implementation of [Jaeger's tracing example](https://github.com/jaegertracing/jaeger/tree/master/examples/hotrod) featuring a few microservices using [Vapor](https://github.com/vapor/vapor), [gRPC](https://github.com/grpc/grpc-swift), and [AsyncHTTPClient](https://github.com/swift-server/async-http-client).
