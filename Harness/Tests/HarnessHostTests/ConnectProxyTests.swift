// Each test is self-contained: it builds its own values and states its own expectations, so it
// can be copied into another file and still run. Nothing here is shared but the imports.

import Foundation
import HarnessHost
import NIOCore
import NIOPosix
import Testing

@Suite("ConnectProxy")
struct ConnectProxyTests {
    @Test("A request other than CONNECT is refused with 405")
    func refusesOtherMethods() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "bh-test-\(UUID().uuidString.prefix(8)).sock").path
        let proxy = try await ConnectProxy.start(socketPath: path)
        defer { Task { await proxy.stop() } }
        let reply = try await exchange(socketPath: path, request: "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 405"))
    }

    @Test("CONNECT to a port that is not allowed is refused with 403")
    func refusesOtherPorts() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "bh-test-\(UUID().uuidString.prefix(8)).sock").path
        let proxy = try await ConnectProxy.start(socketPath: path, allowedPorts: [443])
        defer { Task { await proxy.stop() } }
        let reply = try await exchange(socketPath: path, request: "CONNECT example.com:22 HTTP/1.1\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403"))
    }

    @Test("The socket is created readable and writable by its owner only")
    func socketPermissions() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "bh-test-\(UUID().uuidString.prefix(8)).sock").path
        let proxy = try await ConnectProxy.start(socketPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        let ownerOnly = 0o600
        #expect(permissions == ownerOnly)
        await proxy.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("CONNECT to an allowed port joins the client to the target, in both directions")
    func tunnels() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { echo.close(promise: nil) }
        let port = try #require(echo.localAddress?.port)
        let path = FileManager.default.temporaryDirectory.appending(path: "bh-test-\(UUID().uuidString.prefix(8)).sock").path
        let proxy = try await ConnectProxy.start(socketPath: path, allowedPorts: [port])
        defer { Task { await proxy.stop() } }

        let reply = try await exchange(
            socketPath: path,
            request: "CONNECT 127.0.0.1:\(port) HTTP/1.1\r\n\r\nhello",
            until: "hello"
        )
        #expect(reply.hasPrefix("HTTP/1.1 200"))
        #expect(reply.hasSuffix("hello"))
    }

    /// Sends `request` on the proxy socket and returns what comes back, until `until` arrives or
    /// the connection closes.
    private func exchange(socketPath: String, request: String, until: String? = nil) async throws -> String {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let reply = loop.makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ReplyCollector(reply: reply, until: until))
                }
            }
            .connect(unixDomainSocketPath: socketPath)
            .get()
        try await channel.writeAndFlush(ByteBuffer(string: request))
        let text = try await reply.futureResult.get()
        try? await channel.close()
        return text
    }
}

private final class EchoHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Collects what a connection reads, on its event loop, and completes `reply` with it.
private final class ReplyCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let reply: EventLoopPromise<String>
    private let until: String?
    private var text = ""
    private var replied = false

    init(reply: EventLoopPromise<String>, until: String?) {
        self.reply = reply
        self.until = until
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        text += String(buffer: unwrapInboundIn(data))
        if let until, text.hasSuffix(until), !replied {
            replied = true
            reply.succeed(text)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !replied {
            replied = true
            reply.succeed(text)
        }
    }
}
