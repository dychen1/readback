import Foundation
import NIOCore

/// Connects a client disconnect to the reading that ReadBack starts for that client.
/// The client can leave before the reading exists, so this keeps that fact until
/// `onLeave` gets the action. The action runs exactly once.
final class ClientDisconnectSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var left = false
    private var action: (@Sendable () -> Void)?

    func clientLeft() {
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !left else { return nil }
            left = true
            return action
        }
        pending?()
    }

    /// Runs `action` when the client leaves, or immediately if it already left.
    func onLeave(_ action: @escaping @Sendable () -> Void) {
        let alreadyLeft = lock.withLock { () -> Bool in
            self.action = action
            return left
        }
        if alreadyLeft { action() }
    }
}

/// Reports when an HTTP client goes away while ReadBack still handles its request.
///
/// Hummingbird enables remote half-closure, so a client that hangs up usually arrives
/// as `inputClosed` while the channel stays open. The channel closes only after the
/// response is written. This also treats a client that half-closes on purpose and
/// still waits for the response as gone. No ReadBack client does that.
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
