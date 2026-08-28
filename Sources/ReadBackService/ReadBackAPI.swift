import Foundation
import Hummingbird
import HummingbirdWebSocket
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

private enum PublicSpeechRequestError: Error {
    case modelSelectionNotAllowed
}

private struct ServiceErrorResponse: Encodable {
    struct Detail: Encodable {
        let code: String
        let message: String
    }

    let error: Detail
}

private struct StreamSpeechSettings: Sendable {
    let voice: String?
    let languageCode: String?
    let synthesisSpeed: Double
    let paragraphPause: Double
}

public final class ReadBackAPI: @unchecked Sendable {
    public let configuration: AppConfiguration
    private let modelManager: any ModelManaging
    private let coordinator: SpeechCoordinator
    private let speechSettings: SpeechSettingsStore
    private let encoder = JSONEncoder()

    public init(
        configuration: AppConfiguration,
        modelManager: any ModelManaging,
        coordinator: SpeechCoordinator,
        speechSettings: SpeechSettingsStore? = nil
    ) {
        self.configuration = configuration
        self.modelManager = modelManager
        self.coordinator = coordinator
        self.speechSettings = speechSettings ?? SpeechSettingsStore(configuration: configuration)
    }

    public func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)

        router.get("/health") { [self] _, _ -> HealthResponse in
            let snapshot = await modelManager.snapshot()
            let runtime = Self.runtimeName(snapshot.runtimeState)
            let installed = snapshot.activeModelID.flatMap { activeID in
                snapshot.models.first { $0.id == activeID }
            }.map { Self.isInstalled($0.storageState) } ?? false
            return HealthResponse(
                status: runtime == "ready" ? "ok" : runtime,
                runtime: runtime,
                activeModel: snapshot.activeModelID?.rawValue,
                modelInstalled: installed
            )
        }

        router.post("/v1/audio/speech") { [self] request, context -> Response in
            do {
                let publicRequest = try await decodeSpeechRequest(request, context: context)
                let defaults = await activeSettings()
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
            } catch PublicSpeechRequestError.modelSelectionNotAllowed {
                return modelSelectionErrorResponse()
            }
        }

        router.post("/play") { [self] request, context -> Response in
            do {
                let publicRequest = try await decodeSpeechRequest(request, context: context)
                let defaults = await activeSettings()
                let id = UUID().uuidString
                try await coordinator.startSession(id: id) { _ in }
                _ = try await coordinator.enqueue(
                    text: publicRequest.input,
                    voice: publicRequest.voice,
                    languageCode: publicRequest.languageCode,
                    speed: publicRequest.speed ?? defaults.synthesisSpeed
                )
                await coordinator.finishInput()
                await coordinator.waitUntilFinished(sessionID: id)
                return jsonResponse(ActionResponse(ok: true))
            } catch PublicSpeechRequestError.modelSelectionNotAllowed {
                return modelSelectionErrorResponse()
            }
        }

        router.ws("/v1/readback/stream") { [self] inbound, outbound, _ in
            let sessionID = UUID().uuidString
            var chunker = StreamingTextChunker()
            let settings = await activeSettings()
            var pauseBefore = 0.0
            do {
                try await coordinator.startSession(id: sessionID) { [encoder] event in
                    guard let data = try? encoder.encode(event),
                          let text = String(data: data, encoding: .utf8)
                    else { return }
                    try? await outbound.write(.text(text))
                }

                for try await message in inbound.messages(maxSize: 65_536) {
                    guard case .text(let text) = message else { continue }
                    let event = try JSONDecoder().decode(
                        ReadBackClientEvent.self,
                        from: Data(text.utf8)
                    )
                    switch event {
                    case .textAppend(let text):
                        pauseBefore = try await enqueue(
                            chunker.append(text),
                            settings: settings,
                            pauseBefore: pauseBefore
                        )
                    case .inputCommit:
                        pauseBefore = try await enqueue(
                            chunker.flush().map { [$0] } ?? [],
                            settings: settings,
                            pauseBefore: pauseBefore
                        )
                    case .inputDone:
                        _ = try await enqueue(
                            chunker.flush().map { [$0] } ?? [],
                            settings: settings,
                            pauseBefore: pauseBefore
                        )
                        await coordinator.finishInput()
                    case .playbackCancel:
                        await coordinator.cancel()
                        return
                    case .playbackPause:
                        await coordinator.pause()
                    case .playbackResume:
                        await coordinator.resume()
                    }
                }
                await coordinator.cancel()
            } catch {
                await coordinator.cancel()
                let event = ReadBackServerEvent(
                    type: .error,
                    sessionID: sessionID,
                    message: String(describing: error)
                )
                if let data = try? encoder.encode(event),
                   let text = String(data: data, encoding: .utf8)
                {
                    try? await outbound.write(.text(text))
                }
            }
        }

        return router
    }

    public func run() async throws {
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
        context: BasicWebSocketRequestContext
    ) async throws -> PublicSpeechRequest {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        let data = Data(buffer.readableBytesView)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object.keys.contains("model")
        {
            throw PublicSpeechRequestError.modelSelectionNotAllowed
        }
        return try JSONDecoder().decode(PublicSpeechRequest.self, from: data)
    }

    private func activeSettings() async -> StreamSpeechSettings {
        let snapshot = await modelManager.snapshot()
        let playbackSettings = await speechSettings.current()
        return StreamSpeechSettings(
            voice: snapshot.activePreferences?.voiceID,
            languageCode: nil,
            synthesisSpeed: snapshot.activePreferences?.synthesisSpeed ?? 1,
            paragraphPause: playbackSettings.paragraphPause
        )
    }

    private func enqueue(
        _ segments: [StreamedTextChunk],
        settings: StreamSpeechSettings,
        pauseBefore: Double
    ) async throws -> Double {
        var nextPause = pauseBefore
        for segment in segments {
            while true {
                do {
                    try await coordinator.enqueue(
                        text: segment.text,
                        voice: settings.voice,
                        languageCode: settings.languageCode,
                        speed: settings.synthesisSpeed,
                        pauseBefore: nextPause
                    )
                    nextPause = segment.endsParagraph ? settings.paragraphPause : 0
                    break
                } catch SpeechCoordinatorError.queueLimitExceeded {
                    let clock = ContinuousClock()
                    try await clock.sleep(until: clock.now.advanced(by: .milliseconds(25)))
                }
            }
        }
        return nextPause
    }

    private func modelSelectionErrorResponse() -> Response {
        jsonResponse(
            ServiceErrorResponse(
                error: .init(
                    code: "model_selection_not_allowed",
                    message: "ReadBack uses the model selected in the app."
                )
            ),
            status: .badRequest
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
