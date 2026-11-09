import Foundation
import ReadBackService

func mcpServerSetupTests() -> [TestCase] {
    [
        TestCase(name: "mcp setup builds the Cursor install link from the configured port") {
            let link = MCPServerSetup(host: "127.0.0.1", port: 51999).cursorInstallLink
            let components = try URLComponents(url: link, resolvingAgainstBaseURL: false).unwrap("components")
            try expectEqual(components.scheme, "cursor", "scheme")
            try expectEqual(components.host, "anysphere.cursor-deeplink", "deeplink handler")
            try expectEqual(components.path, "/mcp/install", "path")
            let items = components.queryItems ?? []
            try expectEqual(items.first { $0.name == "name" }?.value, "readback", "server name")
            let encoded = try (items.first { $0.name == "config" }?.value).unwrap("config")
            let config = try String(decoding: Data(base64Encoded: encoded).unwrap("base64"), as: UTF8.self)
            try expectEqual(config, #"{"url":"http://127.0.0.1:51999/mcp"}"#, "decoded config")
        },
        TestCase(name: "mcp setup commands and JSON use the configured endpoint") {
            let setup = MCPServerSetup(host: "127.0.0.1", port: 51281)
            try expectEqual(
                setup.claudeCodeCommand,
                "claude mcp add --transport http --scope user readback http://127.0.0.1:51281/mcp",
                "Claude Code command"
            )
            try expectEqual(
                setup.codexCommand,
                "codex mcp add readback --url http://127.0.0.1:51281/mcp",
                "Codex command"
            )
            let json = try JSONSerialization.jsonObject(with: Data(setup.cursorConfiguration.utf8)) as? [String: Any]
            let servers = json?["mcpServers"] as? [String: Any]
            let readback = servers?["readback"] as? [String: Any]
            try expectEqual(readback?["url"] as? String, "http://127.0.0.1:51281/mcp", "mcp.json entry")
            try expectEqual(
                MCPServerSetup(host: "::1", port: 51280).endpoint,
                "http://[::1]:51280/mcp",
                "IPv6 endpoint"
            )
            let oddHost = MCPServerSetup(host: #"local"host"#, port: 51280)
            let oddJSON = try JSONSerialization.jsonObject(
                with: Data(oddHost.cursorConfiguration.utf8)
            ) as? [String: Any]
            let oddURL = ((oddJSON?["mcpServers"] as? [String: Any])?["readback"] as? [String: Any])?["url"]
            try expectEqual(oddURL as? String, oddHost.endpoint, "a quote in the host keeps the snippet valid JSON")
        },
        TestCase(name: "mcp host recognizes the client names hosts send") {
            try expectEqual(MCPHost(clientName: "cursor-vscode"), .cursor, "Cursor")
            try expectEqual(MCPHost(clientName: "claude-code"), .claudeCode, "Claude Code")
            try expectEqual(MCPHost(clientName: "codex-mcp-client"), .codex, "Codex")
            try expectEqual(MCPHost(clientName: "claude-ai"), nil, "Claude desktop is not Claude Code")
            try expectEqual(MCPHost(clientName: "inspector"), nil, "unknown client")
        },
        TestCase(name: "mcp connection status describes each host") {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let locale = Locale(identifier: "en_US")
            let connections = [
                MCPClientConnection(clientName: "cursor-vscode", clientVersion: "1", lastConnected: now - 30),
                MCPClientConnection(clientName: "claude-code", clientVersion: "2", lastConnected: now - 120),
                MCPClientConnection(clientName: "inspector", clientVersion: "3", lastConnected: now - 3_600),
            ]
            try expectEqual(
                MCPConnectionStatus.text(for: .cursor, connections: connections, now: now, locale: locale),
                "Last connected just now",
                "recent connection"
            )
            try expectEqual(
                MCPConnectionStatus.text(for: .claudeCode, connections: connections, now: now, locale: locale),
                "Last connected 2 minutes ago",
                "older connection"
            )
            try expectEqual(
                MCPConnectionStatus.text(for: .codex, connections: connections, now: now, locale: locale),
                "No connection yet",
                "never connected"
            )
            try expectEqual(
                MCPConnectionStatus.otherClientsText(connections: connections, now: now, locale: locale),
                "Other clients: inspector. Last connected 1 hour ago.",
                "other clients"
            )
            try expectEqual(
                MCPConnectionStatus.otherClientsText(connections: Array(connections.prefix(2)), now: now),
                nil,
                "no other clients"
            )
        },
        TestCase(name: "mcp client registry persists recent clients, newest first and bounded") {
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("readback-mcp-clients-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: storeURL) }
            let clock = TestClock()
            let registry = MCPClientRegistry(storeURL: storeURL, now: { clock.next() })
            await registry.record(clientName: "codex-mcp-client", version: "0.165.0")
            await registry.record(clientName: "cursor-vscode", version: "1.0.0")
            await registry.record(clientName: "codex-mcp-client", version: "0.166.0")
            await registry.record(clientName: "bad\u{07}\nname" + String(repeating: "x", count: 200), version: "1")

            let reloaded = await MCPClientRegistry(storeURL: storeURL).snapshot()
            try expectEqual(reloaded.count, 3, "one entry per client name")
            try expectEqual(reloaded[1].clientName, "codex-mcp-client", "reconnect moves a client forward")
            try expectEqual(reloaded[1].clientVersion, "0.166.0", "latest version is kept")
            try expectEqual(reloaded[2].clientName, "cursor-vscode", "oldest last")
            try expect(reloaded[0].clientName.count <= 80, "client name is bounded")
            try expect(
                !reloaded[0].clientName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                "control characters are removed"
            )

            for index in 0..<30 {
                await registry.record(clientName: "client-\(index)", version: "1")
            }
            let bounded = await registry.snapshot()
            try expectEqual(bounded.count, 20, "registry keeps a bounded number of clients")
            try expectEqual(bounded.first?.clientName, "client-29", "newest first")
        },
    ]
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)

    func next() -> Date {
        lock.withLock {
            current += 1
            return current
        }
    }
}

private extension Optional {
    func unwrap(_ name: String) throws -> Wrapped {
        guard let self else { throw TestFailure(description: "missing \(name)") }
        return self
    }
}
