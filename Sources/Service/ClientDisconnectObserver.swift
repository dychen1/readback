import NIOCore

/// Reports when an HTTP client goes away while its request is still being handled.
///
/// Hummingbird enables remote half-closure, so a client hanging up usually arrives as
/// `inputClosed` while the channel stays open; the channel only closes once the
/// response is written. A client that half-closes on purpose and still waits for the
/// response is treated as gone too; no ReadBack client does that.
final class ClientDisconnectObserver: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let onDisconnect: @Sendable () -> Void
    private var reported = false

    private init(onDisconnect: @escaping @Sendable () -> Void) {
        self.onDisconnect = onDisconnect
    }

    /// Watches `channel` until `stop` is called with the returned name.
    static func start(
        on channel: any Channel,
        onDisconnect: @escaping @Sendable () -> Void
    ) async throws -> String {
        let name = "readback.disconnect-observer.\(UInt64.random(in: .min ... .max))"
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(
                ClientDisconnectObserver(onDisconnect: onDisconnect),
                name: name,
                position: .first
            )
        }.get()
        return name
    }

    static func stop(_ name: String, on channel: any Channel) {
        channel.pipeline.removeHandler(name: name, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            report()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        report()
        context.fireChannelInactive()
    }

    private func report() {
        guard !reported else { return }
        reported = true
        onDisconnect()
    }
}
