import Foundation
import Hummingbird
import MCP

/// Serves MCP over HTTP at `/mcp` with the SDK's stateless transport.
///
/// Each HTTP request gets a fresh `Server` and transport. The SDK accepts `initialize`
/// only once per server (swift-sdk #144, #219), so a long-lived server would reject
/// every host reconnect. Also, the stateless transport keys in-flight requests by the
/// JSON-RPC id that the client chooses, and those ids collide across clients (#265).
///
/// The response to `initialize` has an `Mcp-Session-Id` header. Clients send it back on
/// later requests, so a `play` call can name the client that started the session. The
/// endpoint keeps no other session state and accepts requests without the header.
struct MCPEndpoint: Sendable {
    /// 1 MiB holds any text an agent should read aloud, and bounds memory per request.
    static let maximumBodySize = 1 << 20

    let tools: ReadBackMCPTools
    let clients: MCPClientRegistry
    let serverVersion: String
    private let validationPipeline: StandardValidationPipeline

    /// - Parameter origin: ReadBack's own origin, `http://<host>:<port>`. It is the only
    ///   browser origin allowed, so a page served from another loopback port or name (a
    ///   dev server, say) cannot call the tools.
    init(tools: ReadBackMCPTools, clients: MCPClientRegistry, serverVersion: String, origin: String) {
        self.tools = tools
        self.clients = clients
        self.serverVersion = serverVersion
        validationPipeline = StandardValidationPipeline(validators: [
            OriginValidator(
                allowedHosts: OriginValidator.localhost().allowedHosts,
                allowedOrigins: [origin]
            ),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    }

    func handle(_ request: Request) async throws -> Response {
        let body = try await request.body.collect(upTo: Self.maximumBodySize)
        var headers: [String: String] = [:]
        for field in request.headers {
            let name = field.name.canonicalName
            headers[name] = headers[name].map { "\($0), \(field.value)" } ?? field.value
        }
        // HTTP/1 `Host` arrives as the request authority, not a header field. The SDK's
        // localhost check (DNS-rebinding protection) only runs when it sees `Host`.
        if let authority = request.head.authority {
            headers["Host"] = authority
        }
        let mcpRequest = MCP.HTTPRequest(
            method: request.method.rawValue,
            headers: headers,
            body: Data(body.readableBytesView),
            path: request.uri.path
        )

        var clientName: String?
        if let requestSessionID = headers[HTTPHeaderName.sessionID.lowercased()] {
            clientName = await clients.clientName(sessionID: requestSessionID)
        }
        let newSessionID = UUID().uuidString
        let transport = StatelessHTTPServerTransport(validationPipeline: validationPipeline)
        let server = await makeServer(clientName: clientName)
        try await server.start(transport: transport) { [clients] client, _ in
            await clients.record(clientName: client.name, version: client.version)
            await clients.remember(clientName: client.name, sessionID: newSessionID)
        }
        let mcpResponse = await transport.handleRequest(mcpRequest)
        await server.stop()

        var fields = HTTPFields()
        for (name, value) in mcpResponse.headers {
            if let fieldName = HTTPFields.Element.Name(name) {
                fields[fieldName] = value
            }
        }
        if mcpResponse.statusCode == 200, await clients.clientName(sessionID: newSessionID) != nil {
            fields[HTTPFields.Element.Name(HTTPHeaderName.sessionID)!] = newSessionID
        }
        let responseBody = mcpResponse.bodyData.map {
            ResponseBody(byteBuffer: ByteBuffer(bytes: $0))
        } ?? ResponseBody()
        return Response(
            status: .init(code: mcpResponse.statusCode),
            headers: fields,
            body: responseBody
        )
    }

    private func makeServer(clientName: String?) async -> Server {
        let server = Server(
            name: "readback",
            version: serverVersion,
            title: "ReadBack",
            instructions: ReadBackMCPTools.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ReadBackMCPTools.definitions)
        }
        await server.withMethodHandler(CallTool.self) { [tools] parameters in
            try await tools.call(parameters, clientName: clientName)
        }
        return server
    }
}
