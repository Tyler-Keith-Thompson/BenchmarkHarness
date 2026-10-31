import Foundation
import NIOCore
import NIOPosix

/// An HTTP `CONNECT` proxy served on a Unix domain socket, through which the guest reaches the
/// network.
///
/// The guest has no network interface of its own. The socket is relayed into the guest, where a
/// bridge offers it to apt, git and SwiftPM as an HTTPS proxy, so their traffic leaves from the
/// host like any other process's, whatever VPN or firewall the host has. Only `CONNECT` is served,
/// only to ``allowedPorts``, and only the socket's owner can open it.
public final class ConnectProxy: Sendable {
    /// The socket's path.
    public let socketPath: String
    /// The ports a `CONNECT` request may name.
    public let allowedPorts: Set<Int>
    private let channel: any Channel

    private init(socketPath: String, allowedPorts: Set<Int>, channel: any Channel) {
        self.socketPath = socketPath
        self.allowedPorts = allowedPorts
        self.channel = channel
    }

    /// Starts a proxy listening at `socketPath`, replacing any socket file already there.
    ///
    /// - Parameters:
    ///   - socketPath: Where to create the socket. At most 103 bytes, the limit of a Unix socket
    ///     address.
    ///   - allowedPorts: The ports a `CONNECT` request may name; any other is refused with `403`.
    ///   - group: The event loops serving connections.
    /// - Throws: When the socket cannot be bound or its permissions set.
    public static func start(
        socketPath: String,
        allowedPorts: Set<Int> = [443],
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> ConnectProxy {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ConnectHandler(allowedPorts: allowedPorts, group: group))
                }
            }
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true)
            .get()
        guard chmod(socketPath, 0o600) == 0 else {
            try? await channel.close()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        return ConnectProxy(socketPath: socketPath, allowedPorts: allowedPorts, channel: channel)
    }

    /// Stops accepting connections and removes the socket file.
    public func stop() async {
        try? await channel.close()
        unlink(socketPath)
    }
}

/// Reads a `CONNECT` request, connects to its target, then joins the two connections.
private final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let allowedPorts: Set<Int>
    private let group: any EventLoopGroup
    private var header = ByteBuffer()
    private var connecting = false

    init(allowedPorts: Set<Int>, group: any EventLoopGroup) {
        self.allowedPorts = allowedPorts
        self.group = group
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        header.writeBuffer(&bytes)
        guard !connecting else { return }
        let text = String(buffer: header)
        guard let end = text.range(of: "\r\n\r\n") else {
            if header.readableBytes > 16 * 1024 { refuse(context: context, status: "431 Request Header Fields Too Large") }
            return
        }
        let requestLine = text[..<end.lowerBound].split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "CONNECT", parts[2].hasPrefix("HTTP/1."),
              let colon = parts[1].lastIndex(of: ":"), let port = Int(parts[1][parts[1].index(after: colon)...])
        else {
            refuse(context: context, status: "405 Method Not Allowed")
            return
        }
        guard allowedPorts.contains(port) else {
            refuse(context: context, status: "403 Forbidden")
            return
        }
        let host = String(parts[1][..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let leftover = header.getSlice(at: header.readerIndex + text[..<end.upperBound].utf8.count,
                                       length: header.readableBytes - text[..<end.upperBound].utf8.count)
        connecting = true
        context.channel.setOption(.autoRead, value: false).whenComplete { _ in }
        let client = context.channel
        let loopBound = NIOLoopBound((handler: self, context: context), eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .connect(host: host, port: port)
            .hop(to: context.eventLoop)
            .whenComplete { result in
                let (handler, context) = loopBound.value
                switch result {
                case let .success(upstream):
                    handler.join(context: context, client: client, upstream: upstream, leftover: leftover)
                case .failure:
                    handler.refuse(context: context, status: "502 Bad Gateway")
                }
            }
    }

    /// Joins the client to its upstream connection. Both are on this handler's event loop: the
    /// upstream connection was made on it.
    private func join(context: ChannelHandlerContext, client: any Channel, upstream: any Channel, leftover: ByteBuffer?) {
        let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
        do {
            try client.pipeline.syncOperations.addHandler(clientGlue)
            try upstream.pipeline.syncOperations.addHandler(upstreamGlue)
        } catch {
            upstream.close(promise: nil)
            client.close(promise: nil)
            return
        }
        if let leftover, leftover.readableBytes > 0 {
            upstream.writeAndFlush(leftover, promise: nil)
        }
        client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection established\r\n\r\n"), promise: nil)
        context.pipeline.syncOperations.removeHandler(self, promise: nil)
        client.setOption(.autoRead, value: true).whenComplete { _ in }
    }

    private func refuse(context: ChannelHandlerContext, status: String) {
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n")))
            .whenComplete { _ in channel.close(promise: nil) }
    }
}

/// Relays everything one channel reads to its partner, with backpressure: a channel stops reading
/// while its partner cannot write.
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}
