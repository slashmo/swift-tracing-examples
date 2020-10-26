# Hot R.O.D. - Rides on Demand

This example is [borrowed from Jaeger](https://github.com/jaegertracing/jaeger/tree/master/examples/hotrod). However,
it doesn't actually use Jaeger but the generic
[`Tracer`](https://github.com/slashmo/gsoc-swift-tracing/blob/main/Sources/Tracing/Tracer.swift) API which allows it to
be used with any tracer.

## Running

Each service is written as an individual Swift package, so it's possible to `swift run` them separately. 
For convenience, we provided a `docker-compose` file that runs everthing at once.

```sh
docker-compose up
```
