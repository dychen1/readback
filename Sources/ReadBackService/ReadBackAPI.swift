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

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case speed
    }
}

public final class ReadBackAPI: @unchecked Sendable {
    public let configuration: AppConfiguration
    private let modelStore: ModelStore
    private let backend: MLXBackendClient
    private let coordinator: SpeechCoordinator
    private let downloader: HuggingFaceModelDownloader
    private let encoder = JSONEncoder()

    public init(
        configuration: AppConfiguration,
        modelStore: ModelStore,
        backend: MLXBackendClient,
        coordinator: SpeechCoordinator,
        downloader: HuggingFaceModelDownloader = .init()
    ) {
        self.configuration = configuration
        self.modelStore = modelStore
        self.backend = backend
        self.coordinator = coordinator
        self.downloader = downloader
    }

    public func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)

        router.get("/health") { [self] _, _ -> HealthResponse in
            let backendState = await backend.isHealthy() ? "ready" : "stopped"
            let installed = try await modelStore.installedModels().contains {
                $0.descriptor.id == configuration.model.id
            }
            return HealthResponse(status: "ok", backend: backendState, modelInstalled: installed)
        }

        router.get("/v1/models") { [self] _, _ -> ModelListResponse in
            let installed = try await modelStore.installedModels().contains {
                $0.descriptor.id == configuration.model.id
            }
            let modelPath = try await modelStore.directoryURL(for: configuration.model.id)
            let loaded = await backend.isModelLoaded(at: modelPath)
            return ModelListResponse(data: [modelResponse(installed: installed, loaded: loaded)])
        }

        router.post("/v1/models/:id/load") { [self] _, context -> ActionResponse in
            let id = context.parameters.get("id") ?? ""
            try requireSupportedModel(id)
            let path = try await modelStore.directoryURL(for: id)
            try await backend.loadModel(at: path)
            return ActionResponse(ok: true)
        }

        router.post("/v1/models/:id/download") { [self] _, context -> ActionResponse in
            let id = context.parameters.get("id") ?? ""
            try requireSupportedModel(id)
            let path = try await modelStore.directoryURL(for: id)
            try await downloader.download(configuration.model, to: path)
            return ActionResponse(ok: true)
        }

        router.delete("/v1/models/:id") { [self] _, context -> ActionResponse in
            let id = context.parameters.get("id") ?? ""
            try requireSupportedModel(id)
            try await modelStore.delete(modelID: id)
            return ActionResponse(ok: true)
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
            let id = UUID().uuidString
            try await coordinator.startSession(id: id) { _ in }
            _ = try await coordinator.enqueue(
                text: publicRequest.input,
                voice: publicRequest.voice ?? configuration.defaultVoice,
                speed: publicRequest.speed ?? configuration.defaultSpeed
            )
            await coordinator.finishInput()
            await coordinator.waitUntilFinished(sessionID: id)
            return ActionResponse(ok: true)
        }

        router.ws("/v1/readback/stream") { [self] inbound, outbound, _ in
            let sessionID = UUID().uuidString
            var chunker = StreamingTextChunker()
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
                        try await enqueue(chunker.append(text))
                    case .inputCommit:
                        try await enqueue(chunker.flush().map { [$0] } ?? [])
                    case .inputDone:
                        try await enqueue(chunker.flush().map { [$0] } ?? [])
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
        let modelPath = try await modelStore.directoryURL(for: modelID)
        return try await backend.synthesize(
            SpeechRequest(
                input: request.input,
                voice: request.voice ?? configuration.defaultVoice,
                speed: request.speed ?? configuration.defaultSpeed,
                format: request.responseFormat ?? .wav
            ),
            modelPath: modelPath
        )
    }

    private func enqueue(_ segments: [String]) async throws {
        for text in segments {
            while true {
                do {
                    try await coordinator.enqueue(
                        text: text,
                        voice: configuration.defaultVoice,
                        speed: configuration.defaultSpeed
                    )
                    break
                } catch SpeechCoordinatorError.queueLimitExceeded {
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
        }
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
