import Foundation
import Hummingbird
import HummingbirdTesting
import ReadBackCore
import ReadBackService

func mcpEndpointTests() -> [TestCase] {
    [
        TestCase(name: "mcp initialize records the client and a fresh request lists tools") {
            let fixture = MCPFixture()
            try await fixture.test { client in
                let initialize = try await client.rpc(
                    "initialize",
                    params: [
                        "protocolVersion": "2025-06-18",
                        "capabilities": [:],
                        "clientInfo": ["name": "claude-code", "version": "2.1.316"],
                    ]
                )
                try expectEqual(initialize.status, 200, "initialize status")
                let serverInfo = initialize.result?["serverInfo"] as? [String: Any]
                try expectEqual(serverInfo?["name"] as? String, "readback", "server name")

                let list = try await client.rpc("tools/list")
                let tools = (list.result?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
                try expectEqual(tools, ["play", "stop"], "tool names")
            }
            let connections = await fixture.clients.snapshot()
            try expectEqual(connections.map(\.clientName), ["claude-code"], "recorded client")
            try expectEqual(connections.first?.host, .claudeCode, "recognized host")
        },
        TestCase(name: "mcp play starts a reading and returns before playback finishes") {
            let fixture = MCPFixture(player: APIAudioPlayer(blocking: true))
            try await fixture.test { client in
                let play = try await client.callTool("play", arguments: ["text": "Hello from an agent."])
                try expectEqual(play.isError, false, "play succeeds")
                try expect(play.text.contains("Started reading"), "play message: \(play.text)")
                let plays = await fixture.player.playCount()
                try expectEqual(plays, 1, "audio already plays when play returns")
                let active = await fixture.coordinator.hasActiveSession
                try expect(active, "reading continues after play returns")

                let stop = try await client.callTool("stop")
                try expectEqual(stop.text, "Stopped the current reading.", "stop message")
                let stillActive = await fixture.coordinator.hasActiveSession
                try expect(!stillActive, "stop ends the reading")

                let idleStop = try await client.callTool("stop")
                try expectEqual(idleStop.text, "Nothing was playing.", "idle stop message")
            }
        },
        TestCase(name: "mcp play reports a reading that fails before any audio plays") {
            let fixture = MCPFixture(manager: APITestModelManager(failure: "synthesis exploded"))
            try await fixture.test { client in
                let play = try await client.callTool("play", arguments: ["text": "Hello from an agent."])
                try expectEqual(play.isError, true, "a failed reading is a tool error")
                try expect(play.text.contains("synthesis exploded"), "failure message: \(play.text)")
            }
        },
        TestCase(name: "mcp play replaces a reading started elsewhere") {
            let fixture = MCPFixture(player: APIAudioPlayer(blocking: true))
            try await fixture.coordinator.replaceSession(id: "clipboard") { _ in }
            try await fixture.test { client in
                let play = try await client.callTool("play", arguments: ["text": "Agent reading."])
                try expectEqual(play.isError, false, "play succeeds")
            }
            let outcome = await fixture.coordinator.waitUntilFinished(sessionID: "clipboard")
            try expectEqual(outcome, .interrupted, "earlier reading is interrupted")
            await fixture.coordinator.stop()
        },
        TestCase(name: "mcp play reports unusable requests as tool errors") {
            let fixture = MCPFixture()
            try await fixture.coordinator.replaceSession(id: "current") { _ in }
            try await fixture.test { client in
                let empty = try await client.callTool("play", arguments: ["text": "  "])
                try expectEqual(empty.isError, true, "empty text is an error")
                try expect(empty.text.contains("empty"), "empty message: \(empty.text)")

                let missing = try await client.callTool("play", arguments: [:])
                try expectEqual(missing.isError, true, "missing text is an error")
                try expect(missing.text.contains("\"text\""), "missing message: \(missing.text)")
            }
            let current = await fixture.coordinator.currentSessionID
            try expectEqual(current, "current", "invalid calls interrupt nothing")

            let loading = MCPFixture(manager: APITestModelManager(runtimeState: .loading(.kokoro)))
            try await loading.test { client in
                let result = try await client.callTool("play", arguments: ["text": "Too soon."])
                try expectEqual(result.isError, true, "loading model is an error")
                try expect(result.text.contains("loading"), "loading message: \(result.text)")
            }

            let switching = MCPFixture()
            try await switching.gate.beginModelSwitch()
            try await switching.test { client in
                let result = try await client.callTool("play", arguments: ["text": "Mid switch."])
                try expectEqual(result.isError, true, "model switch is an error")
                try expect(result.text.contains("switching"), "switch message: \(result.text)")
            }
        },
        TestCase(name: "mcp play saves history with the host that initialized the connection") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let store = HistoryStore(fileURL: file)
            let fixture = MCPFixture(history: HistoryRecorder(store: store))
            try await fixture.test { client in
                for (name, text) in [("codex-mcp-client", "From Codex."), ("my-agent", "From my agent.")] {
                    let connection = client.onNewConnection()
                    _ = try await connection.rpc(
                        "initialize",
                        params: [
                            "protocolVersion": "2025-06-18",
                            "capabilities": [:],
                            "clientInfo": ["name": name, "version": "1.0"],
                        ]
                    )
                    let play = try await connection.callTool("play", arguments: ["text": text])
                    try expectEqual(play.isError, false, "play from \(name)")
                }
                let anonymous = try await client.onNewConnection()
                    .callTool("play", arguments: ["text": "From an unknown host."])
                try expectEqual(anonymous.isError, false, "play without initialize")
            }
            await fixture.coordinator.stop()
            let entries = try await store.entries()
            try expectEqual(
                entries.map(\.text),
                ["From an unknown host.", "From my agent.", "From Codex."],
                "agent texts"
            )
            try expectEqual(
                entries.map(\.source),
                [.agent(host: nil), .agent(host: "my-agent"), .agent(host: "Codex")],
                "hosts come from initialize on the same connection"
            )
        },
        TestCase(name: "mcp client registry forgets a closed connection") {
            let registry = MCPClientRegistry()
            let connection = ObjectIdentifier(registry)
            await registry.remember(clientName: "claude-code\u{0}", connection: connection)
            let remembered = await registry.clientName(connection: connection)
            try expectEqual(remembered, "claude-code", "control characters removed")
            await registry.forget(connection: connection)
            let forgotten = await registry.clientName(connection: connection)
            try expectEqual(forgotten, nil, "closed connection has no client")
        },
        TestCase(name: "mcp rejects an unknown tool with a protocol error") {
            let fixture = MCPFixture()
            try await fixture.test { client in
                let response = try await client.rpc(
                    "tools/call",
                    params: ["name": "speak", "arguments": [:]]
                )
                let error = response.json?["error"] as? [String: Any]
                try expectEqual(error?["code"] as? Int, -32602, "invalid params code")
            }
        },
        TestCase(name: "mcp enforces transport validation") {
            let fixture = MCPFixture()
            try await fixture.test { client in
                let futureVersion = try await client.rpc(
                    "tools/list",
                    headers: ["MCP-Protocol-Version": "2026-07-28"]
                )
                try expectEqual(futureVersion.status, 400, "unsupported protocol version")

                let foreignOrigin = try await client.rpc(
                    "tools/list",
                    headers: ["Origin": "https://evil.example"]
                )
                try expectEqual(foreignOrigin.status, 403, "browser origin")

                let otherLoopbackPort = try await client.rpc(
                    "tools/list",
                    headers: ["Origin": "http://127.0.0.1:5173"]
                )
                try expectEqual(otherLoopbackPort.status, 403, "page on another loopback port")

                let ownOrigin = try await client.rpc(
                    "tools/list",
                    headers: ["Origin": "http://127.0.0.1:51280"]
                )
                try expectEqual(ownOrigin.status, 200, "ReadBack's own origin")

                let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
                let foreignHost = try await rawHTTPStatus(
                    port: client.port,
                    request: "POST /mcp HTTP/1.1\r\nHost: evil.example:51280\r\n"
                        + "Content-Type: application/json\r\nAccept: application/json\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                )
                try expectEqual(foreignHost, 421, "rebinding host")

                let oversized = try await client.raw(
                    method: "POST",
                    body: String(repeating: " ", count: (1 << 20) + 1)
                )
                try expectEqual(oversized.status, 413, "oversized body")

                let get = try await client.raw(method: "GET", body: "")
                try expectEqual(get.status, 405, "GET has no event stream")
                let delete = try await client.raw(method: "DELETE", body: "")
                try expectEqual(delete.status, 405, "DELETE has no session")
            }
            let active = await fixture.coordinator.hasActiveSession
            try expect(!active, "rejected requests start nothing")
        },
    ]
}

/// Sends a hand-written HTTP/1.1 request, for headers URLSession will not send.
func rawHTTPStatus(port: Int?, request: String) async throws -> Int {
    guard let port else { throw TestFailure(description: "missing live test port") }
    let task = URLSession.shared.streamTask(withHostName: "127.0.0.1", port: port)
    task.resume()
    defer { task.cancel() }
    try await task.write(Data(request.utf8), timeout: 5)
    let (data, _) = try await task.readData(ofMinLength: 12, maxLength: 4_096, timeout: 5)
    let statusLine = String(decoding: data ?? Data(), as: UTF8.self).prefix(while: { $0 != "\r" })
    guard let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
        throw TestFailure(description: "unexpected response: \(statusLine)")
    }
    return status
}

private struct MCPFixture {
    let manager: APITestModelManager
    let player: APIAudioPlayer
    let gate = ReadBackActivityGate()
    let coordinator: SpeechCoordinator
    let clients = MCPClientRegistry()
    let api: ReadBackAPI

    init(
        manager: APITestModelManager = APITestModelManager(),
        player: APIAudioPlayer = APIAudioPlayer(),
        history: HistoryRecorder? = nil
    ) {
        self.manager = manager
        self.player = player
        coordinator = SpeechCoordinator(synthesizer: manager, player: player, activityGate: gate)
        api = ReadBackAPI(
            configuration: AppConfiguration.default(modelDirectory: URL(fileURLWithPath: "/tmp")),
            modelManager: manager,
            coordinator: coordinator,
            mcpClients: clients,
            history: history
        )
    }

    /// Runs over a real loopback connection with URLSession, so requests carry the
    /// `Host: 127.0.0.1:<port>` real hosts send. Hummingbird's test client always
    /// sends `Host: localhost`, which the SDK's localhost check rightly rejects.
    func test(_ body: @escaping @Sendable (MCPTestClient) async throws -> Void) async throws {
        let app = Application(
            router: api.makeRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            guard let port = client.port else { throw TestFailure(description: "missing live test port") }
            try await body(MCPTestClient(port: port))
        }
    }
}

private struct MCPResponse: @unchecked Sendable {
    let status: Int
    let json: [String: Any]?

    var result: [String: Any]? { json?["result"] as? [String: Any] }
}

private struct ToolResult {
    let isError: Bool
    let text: String
}

private struct MCPTestClient: Sendable {
    let port: Int?
    var session: URLSession = .shared

    /// A client whose requests share one new HTTP connection, as a host's requests do.
    func onNewConnection() -> MCPTestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        return MCPTestClient(port: port, session: URLSession(configuration: configuration))
    }

    func rpc(
        _ method: String,
        params: [String: Any] = [:],
        headers extra: [String: String] = [:]
    ) async throws -> MCPResponse {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await raw(method: "POST", body: body, headers: extra)
    }

    func callTool(_ name: String, arguments: [String: Any] = [:]) async throws -> ToolResult {
        let response = try await rpc("tools/call", params: ["name": name, "arguments": arguments])
        guard let result = response.result else {
            throw TestFailure(description: "tools/call \(name) returned no result: \(String(describing: response.json))")
        }
        let content = result["content"] as? [[String: Any]] ?? []
        return ToolResult(
            isError: result["isError"] as? Bool ?? false,
            text: content.compactMap { $0["text"] as? String }.joined()
        )
    }

    func raw(method: String, body: String, headers extra: [String: String] = [:]) async throws -> MCPResponse {
        guard let port else { throw TestFailure(description: "missing live test port") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in extra {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty {
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return MCPResponse(status: status, json: json)
    }
}
