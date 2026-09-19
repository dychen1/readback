import Foundation
import Hummingbird
import HummingbirdTesting
import ReadBackCore
import ReadBackService

private actor APIAudioPlayer: AudioPlaying {
    func play(_ clip: AudioClip) async throws {}
    func stop() async {}
    func pause() async {}
    func resume() async {}
}

private actor APITestModelManager: ModelManaging {
    private var requests: [SpeechRequest] = []

    func snapshot() async -> ModelManagerSnapshot {
        ModelManagerSnapshot(
            models: [
                ModelSnapshot(
                    id: .kokoro,
                    displayName: "Kokoro",
                    origin: .bundled,
                    storageState: .bundled,
                    languages: [],
                    canInstall: false,
                    canRemove: false,
                    canActivate: false
                )
            ],
            activeModelID: .kokoro,
            activePreferences: ModelPreference(
                modelID: .kokoro,
                voiceID: "af_heart",
                languageCode: "en",
                synthesisSpeed: 1
            ),
            runtimeState: .ready(.kokoro),
            operation: .idle
        )
    }

    func updates() async -> AsyncStream<ModelManagerSnapshot> {
        AsyncStream { $0.finish() }
    }

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        requests.append(request)
        return AudioClip(data: Data([0x01]), format: request.format)
    }

    func install(_ id: ModelID) async throws {}
    func installLanguage(_ code: String, for id: ModelID) async throws {}
    func registerLocalModel(at directory: URL) async throws -> ModelID { .local }
    func remove(_ id: ModelID) async throws {}
    func activate(_ id: ModelID) async throws {}
    func updatePreferences(_ preferences: ModelPreference) async throws {}
    func warmConfiguredModel() async {}

    func receivedRequests() -> [SpeechRequest] { requests }
}

func readBackAPITests() -> [TestCase] {
    [
        TestCase(name: "public model management routes do not exist") {
            let fixture = APIFixture()
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            try await app.test(.router) { client in
                for uri in [
                    "/v1/models",
                    "/v1/models/kokoro/load",
                    "/v1/models/kokoro/download",
                ] {
                    try await client.execute(uri: uri, method: .get) { response in
                        try expectEqual(response.status.code, 404, "removed route \(uri)")
                    }
                }
            }
        },
        TestCase(name: "speech rejects a model selector") {
            let fixture = APIFixture()
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            let body = ByteBuffer(string: #"{"model":"kokoro","input":"hello"}"#)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/v1/audio/speech",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    try expectEqual(response.status.code, 400, "speech status")
                    let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
                    try expect(
                        text.contains("model_selection_not_allowed"),
                        "stable error code"
                    )
                }
            }

            let requestCount = await fixture.manager.receivedRequests().count
            try expectEqual(requestCount, 0, "no synthesis")
        },
        TestCase(name: "speech without a model uses the active manager") {
            let fixture = APIFixture()
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            let body = ByteBuffer(string: #"{"input":"hello","response_format":"wav"}"#)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/v1/audio/speech",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    try expectEqual(response.status.code, 200, "speech status")
                }
            }

            let requests = await fixture.manager.receivedRequests()
            try expectEqual(requests.count, 1, "synthesis count")
            try expectEqual(requests[0].input, "hello", "speech input")
            try expectEqual(requests[0].voice, nil, "manager resolves voice")
        },
        TestCase(name: "speech rejects a browser-style cross-origin request") {
            let fixture = APIFixture()
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            let body = ByteBuffer(string: #"{"input":"hello"}"#)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/v1/audio/speech",
                    method: .post,
                    headers: [.contentType: "application/json", .origin: "https://evil.example"],
                    body: body
                ) { response in
                    try expectEqual(response.status.code, 403, "cross-origin speech status")
                }
            }

            let requestCount = await fixture.manager.receivedRequests().count
            try expectEqual(requestCount, 0, "no synthesis for cross-origin request")
        },
        TestCase(name: "play rejects a browser-style cross-origin request") {
            let fixture = APIFixture()
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            let body = ByteBuffer(string: #"{"input":"hello"}"#)

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/play",
                    method: .post,
                    headers: [.contentType: "application/json", .origin: "https://evil.example"],
                    body: body
                ) { response in
                    try expectEqual(response.status.code, 403, "cross-origin play status")
                }
            }
        },
        TestCase(name: "run refuses a non-loopback public host") {
            var configuration = AppConfiguration.default(modelDirectory: URL(fileURLWithPath: "/tmp"))
            configuration.publicHost = "0.0.0.0"
            let manager = APITestModelManager()
            let coordinator = SpeechCoordinator(synthesizer: manager, player: APIAudioPlayer())
            let api = ReadBackAPI(
                configuration: configuration,
                modelManager: manager,
                coordinator: coordinator
            )

            do {
                try await api.run()
                throw TestFailure(description: "non-loopback host must be rejected")
            } catch ReadBackAPIError.hostNotLoopback(let host) {
                try expectEqual(host, "0.0.0.0", "rejected host echoed back")
            }
        },
        TestCase(name: "health reports the active model and runtime") {
            let fixture = APIFixture()
            let app = Application(responder: fixture.api.makeRouter().buildResponder())

            try await app.test(.router) { client in
                try await client.execute(uri: "/health", method: .get) { response in
                    try expectEqual(response.status.code, 200, "health status")
                    let health = try JSONDecoder().decode(HealthResponse.self, from: response.body)
                    try expectEqual(health.runtime, "ready", "runtime")
                    try expectEqual(health.activeModel, "kokoro", "active model")
                    try expect(health.modelInstalled, "model installed")
                }
            }
        },
    ]
}

private struct APIFixture {
    let manager: APITestModelManager
    let api: ReadBackAPI

    init() {
        let manager = APITestModelManager()
        self.manager = manager
        let configuration = AppConfiguration.default(
            modelDirectory: URL(fileURLWithPath: "/tmp")
        )
        let coordinator = SpeechCoordinator(
            synthesizer: manager,
            player: APIAudioPlayer()
        )
        let api = ReadBackAPI(
            configuration: configuration,
            modelManager: manager,
            coordinator: coordinator
        )
        self.api = api
    }
}
