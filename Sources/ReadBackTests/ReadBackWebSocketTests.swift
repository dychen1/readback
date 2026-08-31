import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import ReadBackCore
import ReadBackService

private actor ImmediateSynthesizer: ModelManaging {
    func snapshot() async -> ModelManagerSnapshot {
        ModelManagerSnapshot(
            models: [],
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
        AudioClip(data: Data(), format: .wav)
    }

    func install(_ id: ModelID) async throws {}
    func installLanguage(_ code: String, for id: ModelID) async throws {}
    func registerLocalModel(at directory: URL) async throws -> ModelID { .local }
    func remove(_ id: ModelID) async throws {}
    func activate(_ id: ModelID) async throws {}
    func updatePreferences(_ preferences: ModelPreference) async throws {}
    func warmConfiguredModel() async {}
}

private actor CancelAwareAudioPlayer: AudioPlaying {
    private var stopped = false
    private var pauses = 0
    private var resumes = 0

    func play(_ clip: AudioClip) async throws {
        try await wait(for: .milliseconds(500))
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
                modelManager: runtime,
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
        TestCase(name: "a second connection failing to start does not cancel the first session") {
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
                modelManager: runtime,
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
                        ReadBackClientEvent.textAppend("Hold this session open."),
                        .inputDone,
                    ] {
                        let data = try encoder.encode(event)
                        try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                    }

                    // A second connection while the first session is still active must be
                    // rejected without tearing down the first session's playback.
                    try await client.ws("/v1/readback/stream") { secondInbound, _, _ in
                        var secondIterator = secondInbound.messages(maxSize: 65_536).makeAsyncIterator()
                        guard case .text(let errorText) = try await secondIterator.next() else {
                            throw TestFailure(description: "second connection should receive an event")
                        }
                        let event = try decoder.decode(
                            ReadBackServerEvent.self,
                            from: Data(errorText.utf8)
                        )
                        try expectEqual(
                            event.type,
                            .error,
                            "second connection is rejected, not upgraded into a session"
                        )
                    }

                    // The first session must still be controllable. A handler that
                    // cancelled it in response to the second connection's failed start
                    // would leave no live session to acknowledge this pause.
                    let pauseData = try encoder.encode(ReadBackClientEvent.playbackPause)
                    try await outbound.write(.text(String(decoding: pauseData, as: UTF8.self)))
                    var receivedPaused = false
                    for _ in 0..<6 {
                        guard case .text(let text) = try await iterator.next() else { break }
                        let event = try decoder.decode(ReadBackServerEvent.self, from: Data(text.utf8))
                        if event.type == .playbackPaused {
                            receivedPaused = true
                            break
                        }
                    }
                    try expect(
                        receivedPaused,
                        "first session still acknowledges control after the second connection failed"
                    )

                    let cancelData = try encoder.encode(ReadBackClientEvent.playbackCancel)
                    try await outbound.write(.text(String(decoding: cancelData, as: UTF8.self)))
                }
            }
        },
    ]
}
