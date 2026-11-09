import Foundation

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
    static let maximumClients = 20
    static let maximumFieldLength = 80

    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private var connections: [MCPClientConnection]
    private var continuations: [UUID: AsyncStream<[MCPClientConnection]>.Continuation] = [:]

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
        let printable = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(printable).prefix(maximumFieldLength))
            .trimmingCharacters(in: .whitespaces)
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
