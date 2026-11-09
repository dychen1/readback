import Foundation
import ReadBackCore

/// Agent apps ReadBack shows MCP setup for.
public enum MCPHost: String, CaseIterable, Codable, Sendable {
    case cursor
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .cursor: "Cursor"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The exact client name the host sends in `initialize`.
    public var clientName: String {
        switch self {
        case .cursor: "cursor-vscode"
        case .claudeCode: "claude-code"
        case .codex: "codex-mcp-client"
        }
    }

    /// Recognizes the client name a host sends in `initialize`, such as
    /// `cursor-vscode`, `claude-code`, or `codex-mcp-client`.
    public init?(clientName: String) {
        let name = clientName.lowercased()
        if name.contains("cursor") {
            self = .cursor
        } else if name.contains("claude-code") {
            self = .claudeCode
        } else if name.contains("codex") {
            self = .codex
        } else {
            return nil
        }
    }
}

extension MCPHost {
    /// The history label for an MCP client name. Only an exact known name gets the display
    /// name of its host. A name that only contains one, such as `not-claude-code`, stays as
    /// sent, so it cannot pass as that host.
    static func historyLabel(clientName: String) -> String {
        allCases.first { $0.clientName == clientName }?.displayName ?? clientName
    }
}

public struct MCPClientConnection: Codable, Equatable, Sendable {
    public let clientName: String
    public let clientVersion: String
    public let lastConnected: Date

    public init(clientName: String, clientVersion: String, lastConnected: Date) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.lastConnected = lastConnected
    }

    public var host: MCPHost? {
        MCPHost(clientName: clientName)
    }
}

/// Remembers which MCP clients connected and when, from the client info each sends in
/// `initialize`. The stateless transport carries no client identity on later requests.
public actor MCPClientRegistry {
    /// Settings lists one row per client; 20 covers every host a user runs.
    static let maximumClients = 20
    /// Longer than any real client name or version, short enough for one Settings row.
    static let maximumFieldLength = 80
    static let maximumSessions = 64

    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private var connections: [MCPClientConnection]
    private var continuations: [UUID: AsyncStream<[MCPClientConnection]>.Continuation] = [:]
    /// Client names by MCP session ID, oldest first.
    private var clientNamesBySession: [(sessionID: String, clientName: String)] = []

    /// Loads earlier connections from `storeURL` when given, so status survives an app
    /// restart. Hosts do not reconnect to a stateless server on their own.
    public init(storeURL: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.storeURL = storeURL
        self.now = now
        connections = storeURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder.registry.decode([MCPClientConnection].self, from: $0) }
            ?? []
    }

    /// Most recent first.
    public func snapshot() -> [MCPClientConnection] {
        connections
    }

    /// Yields the connections now and after every change.
    public func updates() -> AsyncStream<[MCPClientConnection]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[MCPClientConnection]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.yield(connections)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func record(clientName: String, version: String) {
        let name = Self.bounded(clientName)
        let connection = MCPClientConnection(
            clientName: name.isEmpty ? "Unnamed client" : name,
            clientVersion: Self.bounded(version),
            lastConnected: now()
        )
        connections.removeAll { $0.clientName == connection.clientName }
        connections.insert(connection, at: 0)
        if connections.count > Self.maximumClients {
            connections.removeLast(connections.count - Self.maximumClients)
        }
        save()
        continuations.values.forEach { $0.yield(connections) }
    }

    /// Remembers that `clientName` started the MCP session `sessionID`. Later requests carry
    /// no client info, only the session ID, so the `play` tool uses this name to label the
    /// history entry. The registry keeps the newest sessions only and does not save them.
    public func remember(clientName: String, sessionID: String) {
        let name = Self.bounded(clientName)
        guard !name.isEmpty else { return }
        clientNamesBySession.removeAll { $0.sessionID == sessionID }
        clientNamesBySession.append((sessionID, name))
        if clientNamesBySession.count > Self.maximumSessions {
            clientNamesBySession.removeFirst(clientNamesBySession.count - Self.maximumSessions)
        }
    }

    /// The client name that started `sessionID`, or `nil` for a session this registry does
    /// not know, for example one from before the app started.
    public func clientName(sessionID: String) -> String? {
        clientNamesBySession.last { $0.sessionID == sessionID }?.clientName
    }

    private func save() {
        guard let storeURL,
              let data = try? JSONEncoder.registry.encode(connections)
        else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Connection status is a convenience. If the file is not writable, only the
        // status after the next restart is lost.
        try? data.write(to: storeURL, options: .atomic)
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func bounded(_ value: String) -> String {
        UntrustedLabel.clean(value, maximumLength: maximumFieldLength)
    }
}

private extension JSONEncoder {
    static var registry: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var registry: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
