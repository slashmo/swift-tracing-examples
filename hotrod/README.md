# Hot R.O.D. - Rides on Demand

This example is [borrowed from Jaeger](https://github.com/jaegertracing/jaeger/tree/master/examples/hotrod). However, it doesn't actually use Jaeger but the generic [`TracingInstrument`](https://github.com/slashmo/gsoc-swift-tracing/blob/main/Sources/TracingInstrumentation/TracingInstrument.swift) API which allows it to be used with any tracer.

## Running

Each service is written as an individual Swift package, so it's possible to `swift run` them separately. For convenience, we provided a main `hotrod` package as well which uses [`ServiceLifecycle`](https://github.com/swift-server/swift-service-lifecycle) to run all services in conjunction. To run the entire example, execute `swift run hotrod` in this example's root directory.
