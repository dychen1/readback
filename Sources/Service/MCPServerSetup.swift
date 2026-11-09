import Foundation

/// What a user copies or clicks to connect a host to ReadBack's MCP server. ReadBack
/// never writes other apps' configuration files itself.
public struct MCPServerSetup: Equatable, Sendable {
    public static let serverName = "readback"
    public static let cursorBundleIdentifier = "com.todesktop.230313mzl4w4u92"

    public let endpoint: String

    public init(host: String, port: Int) {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        endpoint = "http://\(urlHost):\(port)/mcp"
    }

    /// Opens Cursor's MCP install prompt. The `config` parameter is the base64 of the
    /// server's `mcp.json` entry, per https://cursor.com/docs/context/mcp/install-links.
    public var cursorInstallLink: URL {
        let config = Data(Self.json(["url": endpoint]).utf8).base64EncodedString()
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/mcp/install"
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "name", value: Self.serverName),
            URLQueryItem(
                name: "config",
                value: config.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ),
        ]
        return components.url!
    }

    /// The entry to merge into `~/.cursor/mcp.json` when Cursor is not installed here.
    public var cursorConfiguration: String {
        Self.json(["mcpServers": [Self.serverName: ["url": endpoint]]], options: .prettyPrinted)
    }

    public var claudeCodeCommand: String {
        "claude mcp add --transport http --scope user \(Self.serverName) \(endpoint)"
    }

    public var codexCommand: String {
        "codex mcp add \(Self.serverName) --url \(endpoint)"
    }

    private static func json(
        _ object: [String: Any],
        options: JSONSerialization.WritingOptions = []
    ) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: options.union([.sortedKeys, .withoutEscapingSlashes])
        )
        return String(decoding: data, as: UTF8.self)
    }
}

/// The one-line connection status Settings shows for each host.
public enum MCPConnectionStatus {
    public static func text(
        for host: MCPHost,
        connections: [MCPClientConnection],
        now: Date,
        locale: Locale = .current
    ) -> String {
        guard let latest = connections.first(where: { $0.host == host }) else {
            return "No connection yet"
        }
        return "Last connected \(relative(latest.lastConnected, now: now, locale: locale))"
    }

    /// Clients that are not one of the known hosts, or `nil` when there are none.
    public static func otherClientsText(
        connections: [MCPClientConnection],
        now: Date,
        locale: Locale = .current
    ) -> String? {
        let others = connections.filter { $0.host == nil }
        guard let latest = others.first else { return nil }
        let names = others.prefix(3).map(\.clientName).joined(separator: ", ")
        let more = others.count > 3 ? " and \(others.count - 3) more" : ""
        return "Other clients: \(names)\(more). Last connected \(relative(latest.lastConnected, now: now, locale: locale))."
    }

    private static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
