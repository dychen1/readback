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

private actor APITestRuntime: SpeechModelRuntime {
    private var prepared = false

    func prepare() async throws { prepared = true }
    func isPrepared() async -> Bool { prepared }
    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        AudioClip(data: Data(), format: request.format)
    }
}

func readBackAPITests() -> [TestCase] {
    [
        TestCase(name: "models endpoint reports the pinned local install") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = root.appendingPathComponent(ModelDescriptor.kokoro.directoryName)
            try FileManager.default.createDirectory(
                at: model.appendingPathComponent("voices"),
                withIntermediateDirectories: true
            )
            for path in ["config.json", "kokoro-v1_0.safetensors", "voices/af_heart.safetensors"] {
                _ = FileManager.default.createFile(
                    atPath: model.appendingPathComponent(path).path,
                    contents: Data()
                )
            }

            let configuration = AppConfiguration.default(modelDirectory: root)
            let runtime = APITestRuntime()
            let coordinator = SpeechCoordinator(
                synthesizer: runtime,
                player: APIAudioPlayer()
            )
            let api = ReadBackAPI(
                configuration: configuration,
                modelStore: ModelStore(rootURL: root, supportedModels: [.kokoro]),
                runtime: runtime,
                coordinator: coordinator
            )
            let app = Application(responder: api.makeRouter().buildResponder())

            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/models", method: .get) { response in
                    try expectEqual(response.status.code, 200, "models status")
                    let decoded = try JSONDecoder().decode(ModelListResponse.self, from: response.body)
                    try expectEqual(decoded.data.count, 1, "models count")
                    try expect(decoded.data[0].installed, "model should be installed")
                    try expectEqual(decoded.data[0].revision, ModelDescriptor.kokoro.revision, "pinned revision")
                }
            }
        },
    ]
}
