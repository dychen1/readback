import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import ReadBackCore
import ReadBackService

private actor ImmediateSynthesizer: SpeechModelRuntime {
    func prepare() async throws {}
    func isPrepared() async -> Bool { true }

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        AudioClip(data: Data(), format: .wav)
    }
}

private actor CancelAwareAudioPlayer: AudioPlaying {
    private var stopped = false
    private var pauses = 0
    private var resumes = 0

    func play(_ clip: AudioClip) async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    func stop() async {
        stopped = true
    }

    func pause() async { pauses += 1 }

    func resume() async { resumes += 1 }

    func wasStopped() -> Bool {
        stopped
    }

    func pauseCount() -> Int { pauses }
    func resumeCount() -> Int { resumes }
}

func readBackWebSocketTests() -> [TestCase] {
    [
        TestCase(name: "stream accepts playback cancellation after input is done") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = AppConfiguration.default(modelDirectory: root)
            let runtime = ImmediateSynthesizer()
            let player = CancelAwareAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: runtime,
                player: player
            )
            let api = ReadBackAPI(
                configuration: configuration,
                modelStore: ModelStore(rootURL: root, supportedModels: [.kokoro]),
                runtime: runtime,
                coordinator: coordinator
            )
            let router = api.makeRouter()
            let app = Application(
                router: Router(),
                server: .http1WebSocketUpgrade(webSocketRouter: router),
                configuration: .init(address: .hostname("127.0.0.1", port: 0))
            )

            _ = try await app.test(.live) { client in
                try await client.ws("/v1/readback/stream") { inbound, outbound, _ in
                    var iterator = inbound.messages(maxSize: 65_536).makeAsyncIterator()
                    let encoder = JSONEncoder()
                    let decoder = JSONDecoder()

                    guard case .text(let readyText) = try await iterator.next() else {
                        throw TestFailure(description: "missing session ready event")
                    }
                    let ready = try decoder.decode(
                        ReadBackServerEvent.self,
                        from: Data(readyText.utf8)
                    )
                    try expectEqual(ready.type, .sessionReady, "initial stream event")

                    for event in [
                        ReadBackClientEvent.textAppend("Pause and cancel this playback."),
                        .inputDone,
                        .playbackPause,
                    ] {
                        let data = try encoder.encode(event)
                        try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                    }

                    var receivedPaused = false
                    for _ in 0..<6 {
                        guard case .text(let text) = try await iterator.next() else {
                            break
                        }
                        let event = try decoder.decode(
                            ReadBackServerEvent.self,
                            from: Data(text.utf8)
                        )
                        if event.type == .playbackPaused {
                            receivedPaused = true
                            break
                        }
                    }
                    try expect(receivedPaused, "server should acknowledge playback pause")

                    for event in [ReadBackClientEvent.playbackResume, .playbackCancel] {
                        let data = try encoder.encode(event)
                        try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                    }

                    var receivedResumed = false
                    var receivedFinished = false
                    for _ in 0..<6 {
                        guard case .text(let text) = try await iterator.next() else { break }
                        let event = try decoder.decode(
                            ReadBackServerEvent.self,
                            from: Data(text.utf8)
                        )
                        receivedResumed = receivedResumed || event.type == .playbackResumed
                        receivedFinished = receivedFinished || event.type == .sessionFinished
                        if receivedResumed && receivedFinished { break }
                    }
                    try expect(receivedResumed, "server should acknowledge playback resume")
                    try expect(receivedFinished, "server should acknowledge playback cancellation")
                }
            }

            let stopped = await player.wasStopped()
            let pauseCount = await player.pauseCount()
            let resumeCount = await player.resumeCount()
            try expectEqual(pauseCount, 1, "live pause count")
            try expectEqual(resumeCount, 1, "live resume count")
            try expect(stopped, "playback cancellation should stop the active audio player")
        },
    ]
}
