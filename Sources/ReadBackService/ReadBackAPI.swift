import Foundation
import Hummingbird
import HummingbirdWebSocket
import ReadBackCore

public struct HealthResponse: ResponseCodable, Sendable {
    public let status: String
    public let backend: String
    public let modelInstalled: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case backend
        case modelInstalled = "model_installed"
    }
}

public struct ModelResponse: ResponseCodable, Sendable {
    public let id: String
    public let repository: String
    public let revision: String
    public let installed: Bool
    public let loaded: Bool
}

public struct ModelListResponse: ResponseCodable, Sendable {
    public let data: [ModelResponse]
}

public struct ActionResponse: ResponseCodable, Sendable {
    public let ok: Bool
}

public struct PublicSpeechRequest: Decodable, Sendable {
    public let model: String?
    public let input: String
    public let voice: String?
    public let responseFormat: AudioFormat?
    public let speed: Double?
    public let languageCode: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case speed
        case languageCode = "lang_code"
    }
}

public final class ReadBackAPI: @unchecked Sendable {
    public let configuration: AppConfiguration
    private let modelStore: ModelStore
    private let runtime: any SpeechModelRuntime
    private let coordinator: SpeechCoordinator
    private let speechSettings: SpeechSettingsStore
    private let encoder = JSONEncoder()

    public init(
        configuration: AppConfiguration,
        modelStore: ModelStore,
        runtime: any SpeechModelRuntime,
        coordinator: SpeechCoordinator,
        speechSettings: SpeechSettingsStore? = nil
    ) {
        self.configuration = configuration
        self.modelStore = modelStore
        self.runtime = runtime
        self.coordinator = coordinator
        self.speechSettings = speechSettings ?? SpeechSettingsStore(configuration: configuration)
    }

    public func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)

        router.get("/health") { [self] _, _ -> HealthResponse in
            let backendState = await runtime.isPrepared() ? "ready" : "loading"
            let installed = try await modelStore.installedModels().contains {
                $0.descriptor.id == configuration.model.id
            }
            return HealthResponse(status: "ok", backend: backendState, modelInstalled: installed)
        }

        router.get("/v1/models") { [self] _, _ -> ModelListResponse in
            let installed = try await modelStore.installedModels().contains {
                $0.descriptor.id == configuration.model.id
            }
            let loaded = await runtime.isPrepared()
            return ModelListResponse(data: [modelResponse(installed: installed, loaded: loaded)])
        }

        router.post("/v1/models/:id/load") { [self] _, context -> ActionResponse in
            let id = context.parameters.get("id") ?? ""
            try requireSupportedModel(id)
            try await runtime.prepare()
            return ActionResponse(ok: true)
        }

        router.post("/v1/models/:id/download") { [self] _, context -> ActionResponse in
            let id = context.parameters.get("id") ?? ""
            try requireSupportedModel(id)
            try await runtime.prepare()
            return ActionResponse(ok: true)
        }

        router.delete("/v1/models/:id") { [self] _, context -> ActionResponse in
            let id = context.parameters.get("id") ?? ""
            try requireSupportedModel(id)
            throw HTTPError(.conflict, message: "The bundled Kokoro model cannot be deleted")
        }

        router.post("/v1/audio/speech") { [self] request, context -> Response in
            let publicRequest = try await request.decode(as: PublicSpeechRequest.self, context: context)
            let clip = try await synthesize(publicRequest)
            let contentType = clip.format == .wav ? "audio/wav" : "audio/pcm"
            return Response(
                status: .ok,
                headers: [.contentType: contentType],
                body: .init(byteBuffer: .init(data: clip.data))
            )
        }

        router.post("/play") { [self] request, context -> ActionResponse in
            let publicRequest = try await request.decode(as: PublicSpeechRequest.self, context: context)
            let defaults = await speechSettings.current()
            let voice = publicRequest.voice ?? defaults.voice
            let id = UUID().uuidString
            try await coordinator.startSession(id: id) { _ in }
            _ = try await coordinator.enqueue(
                text: publicRequest.input,
                voice: voice,
                languageCode: publicRequest.languageCode
                    ?? KokoroVoiceCatalog.languageCode(forVoiceID: voice)
                    ?? defaults.languageCode,
                speed: publicRequest.speed ?? defaults.synthesisSpeed
            )
            await coordinator.finishInput()
            await coordinator.waitUntilFinished(sessionID: id)
            return ActionResponse(ok: true)
        }

        router.ws("/v1/readback/stream") { [self] inbound, outbound, _ in
            let sessionID = UUID().uuidString
            var chunker = StreamingTextChunker()
            let settings = await speechSettings.current()
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
                    let event = try JSONDecoder().decode(ReadBackClientEvent.self, from: Data(text.utf8))
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
                if let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) {
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

    private func synthesize(_ request: PublicSpeechRequest) async throws -> AudioClip {
        let modelID = request.model ?? configuration.model.id
        try requireSupportedModel(modelID)
        let defaults = await speechSettings.current()
        let voice = request.voice ?? defaults.voice
        return try await runtime.synthesize(
            SpeechRequest(
                input: request.input,
                voice: voice,
                languageCode: request.languageCode
                    ?? KokoroVoiceCatalog.languageCode(forVoiceID: voice)
                    ?? defaults.languageCode,
                speed: request.speed ?? defaults.synthesisSpeed,
                format: request.responseFormat ?? .wav
            )
        )
    }

    private func enqueue(
        _ segments: [StreamedTextChunk],
        settings: SpeechSettings,
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

    private func requireSupportedModel(_ id: String) throws {
        guard id == configuration.model.id else {
            throw HTTPError(.notFound, message: "Unknown model")
        }
    }

    private func modelResponse(installed: Bool, loaded: Bool) -> ModelResponse {
        ModelResponse(
            id: configuration.model.id,
            repository: configuration.model.repository,
            revision: configuration.model.revision,
            installed: installed,
            loaded: loaded
        )
    }
}
