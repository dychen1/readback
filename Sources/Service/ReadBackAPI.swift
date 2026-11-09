import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import ReadBackCore

public struct HealthResponse: ResponseCodable, Sendable {
    public let status: String
    public let runtime: String
    public let activeModel: String?
    public let modelInstalled: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case runtime
        case activeModel = "active_model"
        case modelInstalled = "model_installed"
    }
}

public struct ActionResponse: ResponseCodable, Sendable {
    public let ok: Bool
}

public struct PublicSpeechRequest: Decodable, Sendable {
    public let input: String
    public let voice: String?
    public let responseFormat: AudioFormat?
    public let speed: Double?
    public let languageCode: String?

    private enum CodingKeys: String, CodingKey {
        case input
        case voice
        case responseFormat = "response_format"
        case speed
        case languageCode = "lang_code"
    }
}

/// Request context that keeps the connection's channel, so a handler can see when the
/// client disconnects. Hummingbird does not cancel a handler when that happens.
public struct ReadBackRequestContext: RequestContext, WebSocketRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let webSocket: WebSocketHandlerReference<Self>
    public let channel: any Channel

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        webSocket = .init()
        channel = source.channel
    }
}

private struct ServiceErrorResponse: Encodable {
    struct Detail: Encodable {
        let code: String
        let message: String
    }

    let error: Detail
}

private struct ServiceError: Error {
    let status: HTTPResponse.Status
    let code: String
    let message: String

    static let modelSelectionNotAllowed = ServiceError(
        status: .badRequest,
        code: "model_selection_not_allowed",
        message: "ReadBack uses the model selected in the app."
    )
}

public enum ReadBackAPIError: Error, Equatable, Sendable {
    case hostNotLoopback(String)
}

public final class ReadBackAPI: @unchecked Sendable {
    public let configuration: AppConfiguration
    private let modelManager: any ModelManaging
    private let coordinator: SpeechCoordinator
    private let reader: ReadingStarter
    private let mcp: MCPEndpoint
    private let history: HistoryRecorder?
    private let encoder = JSONEncoder()

    public init(
        configuration: AppConfiguration,
        modelManager: any ModelManaging,
        coordinator: SpeechCoordinator,
        speechSettings: SpeechSettingsStore? = nil,
        mcpClients: MCPClientRegistry = MCPClientRegistry(),
        serverVersion: String = "dev",
        history: HistoryRecorder? = nil
    ) {
        self.configuration = configuration
        self.modelManager = modelManager
        self.coordinator = coordinator
        self.history = history
        let reader = ReadingStarter(
            coordinator: coordinator,
            modelManager: modelManager,
            speechSettings: speechSettings ?? SpeechSettingsStore(configuration: configuration),
            history: history
        )
        self.reader = reader
        mcp = MCPEndpoint(
            tools: ReadBackMCPTools(reader: reader, coordinator: coordinator),
            clients: mcpClients,
            serverVersion: serverVersion,
            origin: "http://\(configuration.publicHost):\(configuration.publicPort)"
        )
    }

    public func makeRouter() -> Router<ReadBackRequestContext> {
        let router = Router(context: ReadBackRequestContext.self)

        router.get("/health") { [self] request, _ -> Response in
            guard isOriginAllowed(request) else { return originRejectedResponse() }
            let snapshot = await modelManager.snapshot()
            let runtime = Self.runtimeName(snapshot.runtimeState)
            let installed = snapshot.activeModelID.flatMap { activeID in
                snapshot.models.first { $0.id == activeID }
            }.map { Self.isInstalled($0.storageState) } ?? false
            return jsonResponse(
                HealthResponse(
                    status: runtime == "ready" ? "ok" : runtime,
                    runtime: runtime,
                    activeModel: snapshot.activeModelID?.rawValue,
                    modelInstalled: installed
                )
            )
        }

        router.post("/v1/audio/speech") { [self] request, context -> Response in
            guard isOriginAllowed(request) else { return originRejectedResponse() }
            do {
                let publicRequest = try await decodeSpeechRequest(request, context: context)
                let defaults = await reader.currentSettings()
                let clip: AudioClip
                do {
                    clip = try await modelManager.synthesize(
                        SpeechRequest(
                            input: publicRequest.input,
                            voice: publicRequest.voice,
                            languageCode: publicRequest.languageCode,
                            speed: publicRequest.speed ?? defaults.synthesisSpeed,
                            format: publicRequest.responseFormat ?? .wav
                        )
                    )
                } catch ModelManagerError.modelNotReady {
                    throw HTTPError(.serviceUnavailable, message: "The active model is not ready")
                }
                let contentType = clip.format == .wav ? "audio/wav" : "audio/pcm"
                return Response(
                    status: .ok,
                    headers: [.contentType: contentType],
                    body: .init(byteBuffer: .init(data: clip.data))
                )
            } catch let error as ServiceError {
                return errorResponse(error)
            }
        }

        router.post("/play") { [self] request, context -> Response in
            guard isOriginAllowed(request) else { return originRejectedResponse() }
            let disconnect = ClientDisconnectSignal()
            let observer = try? await ClientDisconnectObserver.start(on: context.channel) {
                disconnect.clientLeft()
            }
            defer {
                if let observer { ClientDisconnectObserver.stop(observer, on: context.channel) }
            }
            if observer == nil {
                // The channel already closed, so nobody waits for this reading.
                disconnect.clientLeft()
            }
            let id: String
            do {
                let publicRequest = try await decodeSpeechRequest(request, context: context)
                id = try await reader.start(
                    ReadingRequest(
                        text: publicRequest.input,
                        voice: publicRequest.voice,
                        languageCode: publicRequest.languageCode,
                        speed: publicRequest.speed
                    ),
                    historySource: Self.agentSource(request),
                    isAbandoned: { disconnect.hasLeft }
                )
            } catch let error as ServiceError {
                return errorResponse(error)
            } catch let error as ReadingStartError {
                return errorResponse(Self.serviceError(for: error))
            }

            disconnect.onLeave { [coordinator] in
                Task { await coordinator.cancel(sessionID: id) }
            }
            let outcome = await coordinator.waitUntilFinished(sessionID: id)
            switch outcome {
            case .completed:
                return jsonResponse(ActionResponse(ok: true))
            case .interrupted:
                return errorResponse(
                    ServiceError(
                        status: .conflict,
                        code: "interrupted",
                        message: "A newer reading replaced this one before it finished."
                    )
                )
            case .stopped:
                return errorResponse(
                    ServiceError(
                        status: .conflict,
                        code: "stopped",
                        message: "A stop request ended the reading before it finished."
                    )
                )
            case .failed(let message):
                return errorResponse(
                    ServiceError(
                        status: .internalServerError,
                        code: "speech_failed",
                        message: "Speech failed: \(message)"
                    )
                )
            }
        }

        router.post("/mcp") { [mcp] request, context in
            try await mcp.handle(request, channel: context.channel)
        }
        router.get("/mcp") { [mcp] request, context in
            try await mcp.handle(request, channel: context.channel)
        }
        router.delete("/mcp") { [mcp] request, context in
            try await mcp.handle(request, channel: context.channel)
        }

        router.ws("/v1/readback/stream", shouldUpgrade: { [self] request, _ in
            isOriginAllowed(request) ? .upgrade([:]) : .dontUpgrade
        }) { [self] inbound, outbound, context in
            // The coordinator calls the sink while it holds its transition lock. A client
            // that stops reading must not block that lock, so events queue here and a
            // separate task writes them in order.
            let (events, eventQueue) = AsyncStream.makeStream(of: ReadBackServerEvent.self)
            let encoder = self.encoder
            let writer = Task {
                for await event in events {
                    guard let data = try? encoder.encode(event),
                          let text = String(data: data, encoding: .utf8)
                    else { continue }
                    try? await outbound.write(.text(text))
                }
            }
            await runStreamSession(
                inbound: inbound,
                history: makeHistoryStream(for: context.request)
            ) { eventQueue.yield($0) }
            eventQueue.finish()
            await writer.value
        }

        return router
    }

    private func runStreamSession(
        inbound: WebSocketInboundStream,
        history: HistoryStreamRecording,
        send: @escaping SpeechCoordinator.EventSink
    ) async {
        let sessionID = UUID().uuidString
        let sendError: @Sendable (String) async -> Void = { message in
            await send(ReadBackServerEvent(type: .error, sessionID: sessionID, message: message))
        }

        if let unavailable = await reader.unavailableReason() {
            await sendError(unavailable)
            return
        }
        do {
            try await coordinator.replaceSession(id: sessionID, events: send)
        } catch {
            await sendError(ReadingStarter.switchingMessage)
            return
        }

        let settings = await reader.currentSettings()
        var chunker = StreamingTextChunker()
        var history = history
        var pauseBefore = 0.0
        do {
            for try await message in inbound.messages(maxSize: 65_536) {
                guard case .text(let text) = message else { continue }
                let event = try JSONDecoder().decode(
                    ReadBackClientEvent.self,
                    from: Data(text.utf8)
                )
                switch event {
                case .textAppend(let text):
                    if let entryID = await history.append(text) {
                        await coordinator.linkHistoryEntry(entryID, toSession: sessionID)
                    }
                    pauseBefore = try await coordinator.enqueueWaitingForRoom(
                        chunker.append(text),
                        sessionID: sessionID,
                        settings: settings,
                        pauseBefore: pauseBefore
                    )
                case .inputCommit:
                    pauseBefore = try await coordinator.enqueueWaitingForRoom(
                        chunker.flush().map { [$0] } ?? [],
                        sessionID: sessionID,
                        settings: settings,
                        pauseBefore: pauseBefore
                    )
                case .inputDone:
                    history.finish()
                    _ = try await coordinator.enqueueWaitingForRoom(
                        chunker.flush().map { [$0] } ?? [],
                        sessionID: sessionID,
                        settings: settings,
                        pauseBefore: pauseBefore
                    )
                    await coordinator.finishInput(sessionID: sessionID)
                case .playbackCancel:
                    await coordinator.cancel(sessionID: sessionID)
                    return
                case .playbackPause:
                    await coordinator.pause(sessionID: sessionID)
                case .playbackResume:
                    await coordinator.resume(sessionID: sessionID)
                }
            }
            await coordinator.cancel(sessionID: sessionID)
        } catch SpeechCoordinatorError.sessionNotActive {
            // The reading ended or a newer reading replaced it. The client already got
            // `session.finished` with the reason.
        } catch {
            await coordinator.cancel(sessionID: sessionID)
            await sendError(String(describing: error))
        }
    }

    public func run() async throws {
        guard Self.isLoopbackHost(configuration.publicHost) else {
            throw ReadBackAPIError.hostNotLoopback(configuration.publicHost)
        }
        let router = makeRouter()
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(
                address: .hostname(configuration.publicHost, port: configuration.publicPort)
            )
        )
        try await app.runService()
    }

    private func decodeSpeechRequest(
        _ request: Request,
        context: ReadBackRequestContext
    ) async throws -> PublicSpeechRequest {
        let data: Data
        do {
            let buffer = try await request.body.collect(upTo: context.maxUploadSize)
            data = Data(buffer.readableBytesView)
        } catch is NIOTooManyBytesError {
            throw ServiceError(
                status: .contentTooLarge,
                code: "request_too_large",
                message: "The request body is larger than \(context.maxUploadSize) bytes."
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError(
                status: .badRequest,
                code: "invalid_json",
                message: "The request body must be a JSON object."
            )
        }
        if object.keys.contains("model") {
            throw ServiceError.modelSelectionNotAllowed
        }
        do {
            return try JSONDecoder().decode(PublicSpeechRequest.self, from: data)
        } catch {
            throw ServiceError(
                status: .badRequest,
                code: "invalid_request",
                message: Self.describe(error)
            )
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _):
            "The required field \"\(key.stringValue)\" is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .dataCorrupted(let context):
            "The field \"\(context.codingPath.map(\.stringValue).joined(separator: "."))\" has an invalid value."
        default:
            "The request body is not a valid speech request."
        }
    }

    private static func serviceError(for error: ReadingStartError) -> ServiceError {
        let code = switch error {
        case .emptyText: "empty_input"
        case .speedOutOfRange: "invalid_speed"
        case .invalidVoice: "invalid_voice"
        case .invalidLanguage: "invalid_language"
        case .modelUnavailable: "model_not_ready"
        case .abandoned: "client_left"
        }
        return ServiceError(
            status: error.isInvalidRequest ? .badRequest : .serviceUnavailable,
            code: code,
            message: error.message
        )
    }

    /// Returns the stream URL for the app's own connection. The app records clipboard reads
    /// itself and skips previews and replays. This URL tells the server not to record the stream.
    public static func historySkippingStreamURL(host: String, port: Int) -> URL? {
        URL(string: "ws://\(host):\(port)/v1/readback/stream?history=skip")
    }

    private static func agentSource(_ request: Request) -> HistorySource {
        let host = request.headers.first { $0.name.canonicalName == "x-readback-client" }?.value
        return .agent(reportedHost: host)
    }

    private func makeHistoryStream(for request: Request) -> HistoryStreamRecording {
        guard let history, request.uri.queryParameters.get("history") != "skip" else {
            return .disabled
        }
        return history.stream(source: .voicepipe)
    }

    private func isOriginAllowed(_ request: Request) -> Bool {
        // Most native local clients (voicepipe's URLSessionWebSocketTask, curl) never
        // send an Origin header, so a missing header is always allowed. Some WebSocket
        // client libraries, such as the vendored swift-websocket in tests, send their
        // own `ws://` URL without a port. Browsers never send a `ws` origin. A browser
        // origin must be exactly the address this service listens on. The check refuses
        // any other page, even one from another loopback port or name such as a dev
        // server on `localhost`.
        // A DNS-rebinding page sends its own name as `Host`, so a non-loopback `Host`
        // is refused too. Hummingbird's test client sends `localhost` with no port.
        if let authority = request.head.authority {
            guard let host = URLComponents(string: "http://\(authority)")?.host,
                  Self.isLoopbackHost(host)
            else { return false }
        }
        guard let origin = request.headers[.origin] else { return true }
        guard let url = URL(string: origin), let host = url.host else { return false }
        switch url.scheme {
        case "ws", "wss": return Self.isLoopbackHost(host)
        case "http": return host == configuration.publicHost && url.port == configuration.publicPort
        default: return false
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    private func originRejectedResponse() -> Response {
        errorResponse(
            ServiceError(
                status: .forbidden,
                code: "origin_not_allowed",
                message: "ReadBack accepts browser requests only from its own origin and address."
            )
        )
    }

    private func errorResponse(_ error: ServiceError) -> Response {
        jsonResponse(
            ServiceErrorResponse(error: .init(code: error.code, message: error.message)),
            status: error.status
        )
    }

    private func jsonResponse<Value: Encodable>(
        _ value: Value,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        let data = (try? encoder.encode(value)) ?? Data()
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private static func runtimeName(_ state: ModelRuntimeState) -> String {
        switch state {
        case .starting: "starting"
        case .loading, .unloading: "loading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    private static func isInstalled(_ state: ModelStorageState) -> Bool {
        switch state {
        case .bundled, .installed, .localAvailable: true
        default: false
        }
    }
}
