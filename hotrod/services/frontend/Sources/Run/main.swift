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
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import AsyncHTTPClient
import Baggage
import BaggageLogging
import Foundation
import FrontendService
import Logging
import NIO
import NIOHTTP1

struct FrontendServiceContext: LoggingBaggageContextCarrier {
    var baggage: BaggageContext

    private var _logger: Logger

    init(logger: Logger, baggage: BaggageContext) {
        self._logger = logger
        self.baggage = baggage
    }

    var logger: Logger {
        get {
            self._logger.with(context: self.baggage)
        }
        set {
            self._logger = newValue
        }
    }
}

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

struct Customer: Codable {
    let id: String
    let name: String
    let location: String
}

private func httpResponseHead(request: HTTPRequestHead, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) -> HTTPResponseHead {
    var head = HTTPResponseHead(version: request.version, status: status, headers: headers)
    let connectionHeaders: [String] = head.headers[canonicalForm: "connection"].map { $0.lowercased() }

    if !connectionHeaders.contains("keep-alive"), !connectionHeaders.contains("close") {
        // the user hasn't pre-set either 'keep-alive' or 'close', so we might need to add headers
        switch (request.isKeepAlive, request.version.major, request.version.minor) {
        case (true, 1, 0):
            // HTTP/1.0 and the request has 'Connection: keep-alive', we should mirror that
            head.headers.add(name: "Connection", value: "keep-alive")
        case (false, 1, let n) where n >= 1:
            // HTTP/1.1 (or treated as such) and the request has 'Connection: close', we should mirror that
            head.headers.add(name: "Connection", value: "close")
        default:
            // we should match the default or are dealing with some HTTP that we don't support, let's leave as is
            ()
        }
    }
    return head
}

private final class HTTPHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger
    private var client: HTTPClient!
    private let customerServiceBaseURL: String

    private enum State {
        case idle
        case waitingForRequestBody
        case sendingResponse

        mutating func requestReceived() {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody
        }

        mutating func requestComplete() {
            precondition(self == .waitingForRequestBody, "Invalid state for request complete: \(self)")
            self = .sendingResponse
        }

        mutating func responseComplete() {
            precondition(self == .sendingResponse, "Invalid state for response complete: \(self)")
            self = .idle
        }
    }

    private var buffer: ByteBuffer!
    private var keepAlive = false
    private var state = State.idle
    private let htdocsPath: String

    private var infoSavedRequestHead: HTTPRequestHead?
    private var infoSavedBodyBytes: Int = 0

    private var continuousCount: Int = 0

    private var handler: ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)?
    private var handlerFuture: EventLoopFuture<Void>?
    private let fileIO: NonBlockingFileIO

    public init(fileIO: NonBlockingFileIO, htdocsPath: String, logger: Logger) throws {
        self.htdocsPath = htdocsPath
        self.fileIO = fileIO
        self.logger = logger
        guard let customerServiceBaseURL = ProcessInfo.processInfo.environment["CUSTOMER_SERVICE_BASE_URL"] else {
            throw FrontendServiceError.missingCustomerServiceBaseURL
        }
        self.customerServiceBaseURL = customerServiceBaseURL
    }

    func channelActive(context: ChannelHandlerContext) {
        self.client = HTTPClient(eventLoopGroupProvider: .shared(context.eventLoop))
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.client.shutdown { error in
            if let error = error {
                self.logger.error("Error shutting down HTTPClient: \(error)")
            }
        }
    }

    private func handleDispatch(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head:
            self.state.requestReceived()
        case .body:
            break
        case .end:
            let version = HTTPVersion(major: 1, minor: 1)

            self.state.requestComplete()

            let serviceContext = FrontendServiceContext(logger: self.logger, baggage: context.baggage)
            self.client
                .get(url: self.customerServiceBaseURL + "/customer?customer=123", context: serviceContext)
                .flatMapThrowing { response -> Customer in
                    if case .ok = response.status, let body = response.body {
                        let jsonDecoder = JSONDecoder()
                        let customerData = body.getData(at: 0, length: body.readableBytes)!
                        return try jsonDecoder.decode(Customer.self, from: customerData)
                    } else {
                        throw FrontendServiceError.internalServerError
                    }
                }
                .whenComplete { result in
                    switch result {
                    case .success(let customer):
                        // TODO: - Fetch matching driver for customer location
                        serviceContext.logger.info("Fetch driver near location: \(customer.location)")
                        let driver = "Swift"

                        // TODO: - Fetch fasted route
                        serviceContext.logger
                            .info(#"Fetch ETA to match customer "\#(customer.name)" and driver "\#(driver)""#)
                        let eta = .random(in: 3 ... 20) * 60000
                        self.buffer.clear()
                        self.buffer.writeString(#"{"Driver": "Swift", "ETA": \#(eta)}"#)

                        let responseHead = HTTPResponseHead(version: version, status: .ok, headers: [
                            "content-type": "application/json",
                            "content-length": "\(self.buffer.readableBytes)",
                        ])
                        context.writeAndFlush(self.wrapOutboundOut(.head(responseHead)), promise: nil)

                        context.write(self.wrapOutboundOut(.body(.byteBuffer(self.buffer.slice()))), promise: nil)
                        self.completeResponse(context, trailers: nil, promise: nil)
                    case .failure:
                        let responseHead = HTTPResponseHead(version: version, status: .internalServerError)
                        context.writeAndFlush(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                        self.completeResponse(context, trailers: nil, promise: nil)
                    }
                }
        }
    }

    private func handleFile(context: ChannelHandlerContext, request: HTTPServerRequestPart, path: String) {
        self.buffer.clear()

        func sendErrorResponse(request: HTTPRequestHead, _ error: Error) {
            var body = context.channel.allocator.buffer(capacity: 128)
            let response = { () -> HTTPResponseHead in
                switch error {
                case let e as IOError where e.errnoCode == ENOENT:
                    body.writeStaticString("IOError (not found)\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                case let e as IOError:
                    body.writeStaticString("IOError (other)\r\n")
                    body.writeString(e.description)
                    body.writeStaticString("\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                default:
                    body.writeString("\(type(of: error)) error\r\n")
                    return httpResponseHead(request: request, status: .internalServerError)
                }
            }()
            body.writeString("\(error)")
            body.writeStaticString("\r\n")
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.channel.close(promise: nil)
        }

        func responseHead(request: HTTPRequestHead, fileRegion region: FileRegion) -> HTTPResponseHead {
            var response = httpResponseHead(request: request, status: .ok)
            response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
            response.headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
            return response
        }

        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()
            guard !request.uri.containsDotDot() else {
                let response = httpResponseHead(request: request, status: .forbidden)
                context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
                return
            }
            let path = self.htdocsPath + "/" + path
            let fileHandleAndRegion = self.fileIO.openFile(path: path, eventLoop: context.eventLoop)
            fileHandleAndRegion.whenFailure {
                sendErrorResponse(request: request, $0)
            }
            fileHandleAndRegion.whenSuccess { file, region in
                var responseStarted = false
                let response = responseHead(request: request, fileRegion: region)
                if region.readableBytes == 0 {
                    responseStarted = true
                    context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                }
                return self.fileIO.readChunked(
                    fileRegion: region,
                    chunkSize: 32 * 1024,
                    allocator: context.channel.allocator,
                    eventLoop: context.eventLoop
                ) { buffer in
                    if !responseStarted {
                        responseStarted = true
                        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                    }
                    return context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                }.flatMap { () -> EventLoopFuture<Void> in
                    let p = context.eventLoop.makePromise(of: Void.self)
                    self.completeResponse(context, trailers: nil, promise: p)
                    return p.futureResult
                }.flatMapError { error in
                    if !responseStarted {
                        let response = httpResponseHead(request: request, status: .ok)
                        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                        var buffer = context.channel.allocator.buffer(capacity: 100)
                        buffer.writeString("fail: \(error)")
                        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        self.state.responseComplete()
                        return context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
                    } else {
                        return context.close()
                    }
                }.whenComplete { (_: Result<Void, Error>) in
                    _ = try? file.close()
                }
            }
        case .end:
            self.state.requestComplete()
        default:
            fatalError("oh noes: \(request)")
        }
    }

    private func completeResponse(_ context: ChannelHandlerContext, trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?) {
        self.state.responseComplete()

        let promise = self.keepAlive ? promise : (promise ?? context.eventLoop.makePromise())
        if !self.keepAlive {
            promise!.futureResult.whenComplete { (_: Result<Void, Error>) in context.close(promise: nil) }
        }
        self.handler = nil

        context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if let handler = self.handler {
            handler(context, reqPart)
            return
        }

        switch reqPart {
        case .head(let request):
            if request.uri.starts(with: "/dispatch") {
                self.handler = { self.handleDispatch(context: $0, request: $1) }
                self.handler!(context, reqPart)
            } else {
                let path = request.uri == "/" ? "index.html" : request.uri
                self.handler = { self.handleFile(context: $0, request: $1, path: path) }
                self.handler!(context, reqPart)
            }
        case .body:
            break
        case .end:
            self.state.requestComplete()
            let content = HTTPServerResponsePart.body(.byteBuffer(self.buffer!.slice()))
            context.write(self.wrapOutboundOut(content), promise: nil)
            self.completeResponse(context, trailers: nil, promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel. At this time, any
            // outstanding response will now get the channel closed, and
            // if we are idle or waiting for a request body to finish we
            // will close the channel immediately.
            switch self.state {
            case .idle, .waitingForRequestBody:
                context.close(promise: nil)
            case .sendingResponse:
                self.keepAlive = false
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

// First argument is the program path
var arguments = CommandLine.arguments.dropFirst(0) // just to get an ArraySlice<String> from [String]
var allowHalfClosure = true
if arguments.dropFirst().first == .some("--disable-half-closure") {
    allowHalfClosure = false
    arguments = arguments.dropFirst()
}

let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first
let arg3 = arguments.dropFirst(3).first

let htdocs = "Public"

let logger = Logger(label: "hotrod.frontend")
let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
let threadPool = NIOThreadPool(numberOfThreads: 6)
threadPool.start()

func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
        try! channel.pipeline.addHandler(HTTPHandler(fileIO: fileIO, htdocsPath: htdocs, logger: logger))
    }
}

let fileIO = NonBlockingFileIO(threadPool: threadPool)
let socketBootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer(childChannelInitializer(channel:))

    // Enable SO_REUSEADDR for the accepted Channels
    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
    .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: allowHalfClosure)

defer {
    try! group.syncShutdownGracefully()
    try! threadPool.syncShutdownGracefully()
}

guard let port = ProcessInfo.processInfo.environment["FRONTEND_SERVICE_PORT"].flatMap(Int.init) else {
    fatalError("Missing or invalid port. Make sure to set it via the FRONTEND_SERVICE_PORT environment variable.")
}

let channel = try socketBootstrap.bind(host: "localhost", port: port).wait()

let localAddress: String
guard let channelLocalAddress = channel.localAddress else {
    fatalError("Address was unable to bind. Please check that the socket was not closed or that the address family was understood.")
}

localAddress = "\(channelLocalAddress)"
print("Server started and listening on \(localAddress), htdocs path \(htdocs)")

// This will never unblock as we don't close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
