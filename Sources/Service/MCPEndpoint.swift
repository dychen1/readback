import Foundation
import Hummingbird
import MCP

/// Serves MCP over HTTP at `/mcp` with the SDK's stateless transport.
///
/// Each HTTP request gets a fresh `Server` and transport. The SDK accepts `initialize`
/// only once per server (swift-sdk #144, #219), so a long-lived server would reject
/// every host reconnect, and the stateless transport keys in-flight requests by the
/// client-chosen JSON-RPC id, which collides across clients (#265).
struct MCPEndpoint: Sendable {
    static let maximumBodySize = 1 << 20

    let tools: ReadBackMCPTools
    let clients: MCPClientRegistry
    let serverVersion: String

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

        let transport = StatelessHTTPServerTransport()
        let server = await makeServer()
        try await server.start(transport: transport) { [clients] client, _ in
            await clients.record(clientName: client.name, version: client.version)
        }
        let mcpResponse = await transport.handleRequest(mcpRequest)
        await server.stop()

        var fields = HTTPFields()
        for (name, value) in mcpResponse.headers {
            if let fieldName = HTTPFields.Element.Name(name) {
                fields[fieldName] = value
            }
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

    private func makeServer() async -> Server {
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
            try await tools.call(parameters)
        }
        return server
    }
}
