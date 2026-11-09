import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import ReadBackCore
import WSCore
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
        TestCase(name: "a newer stream replaces the current one and the old stream cannot affect it") {
            let fixture = LiveFixture(player: APIAudioPlayer(blocking: true))
            _ = try await fixture.app.test(.live) { client in
                try await client.ws("/v1/readback/stream") { oldInbound, oldOutbound, _ in
                    var oldEvents = oldInbound.messages(maxSize: 65_536).makeAsyncIterator()
                    _ = try await nextEvent(&oldEvents, ofType: .sessionReady)
                    try await send(.textAppend("The old stream is reading."), to: oldOutbound)
                    await fixture.player.waitUntilPlaying()

                    try await client.ws("/v1/readback/stream") { newInbound, newOutbound, _ in
                        var newEvents = newInbound.messages(maxSize: 65_536).makeAsyncIterator()
                        let newReady = try await nextEvent(&newEvents, ofType: .sessionReady)

                        for event in [ReadBackClientEvent.textAppend("Late text."), .playbackPause, .playbackCancel] {
                            try? await send(event, to: oldOutbound)
                        }
                        try await wait(for: .milliseconds(50))
                        let current = await fixture.coordinator.currentSessionID
                        let inputs = await fixture.manager.receivedRequests().map(\.input)
                        try expectEqual(current, newReady.sessionID, "old stream cannot end the new one")
                        try expect(!inputs.contains("Late text."), "late text never reaches the new reading")

                        try await send(.textAppend("The new stream is reading."), to: newOutbound)
                        try await send(.playbackPause, to: newOutbound)
                        _ = try await nextEvent(&newEvents, ofType: .playbackPaused)
                        try await send(.playbackCancel, to: newOutbound)
                    }

                    let oldFinished = try await nextEvent(&oldEvents, ofType: .sessionFinished)
                    try expectEqual(oldFinished.reason, .interrupted, "old stream learns why it ended")
                }
            }
        },
        TestCase(name: "play replaces a streaming session") {
            let fixture = LiveFixture(player: APIAudioPlayer(blocking: true))
            _ = try await fixture.app.test(.live) { client in
                try await client.ws("/v1/readback/stream") { inbound, outbound, _ in
                    var events = inbound.messages(maxSize: 65_536).makeAsyncIterator()
                    _ = try await nextEvent(&events, ofType: .sessionReady)
                    try await send(.textAppend("Streaming text."), to: outbound)
                    await fixture.player.waitUntilPlaying()

                    let play = Task {
                        try await client.execute(
                            uri: "/play",
                            method: .post,
                            headers: [.contentType: "application/json"],
                            body: ByteBuffer(string: #"{"input":"Play wins."}"#)
                        )
                    }
                    let finished = try await nextEvent(&events, ofType: .sessionFinished)
                    try expectEqual(finished.reason, .interrupted, "stream is interrupted by play")

                    while await fixture.player.playCount() < 2 {
                        try await wait(for: .milliseconds(2))
                    }
                    await fixture.player.release()
                    let response = try await play.value
                    try expectEqual(response.status.code, 200, "play completes")
                }
            }
        },
        TestCase(name: "play stops its reading when the client disconnects") {
            let fixture = LiveFixture(player: APIAudioPlayer(blocking: true))
            _ = try await fixture.app.test(.live) { client in
                let port = try client.port.unwrap("live test port")
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/play")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(#"{"input":"Hang up on me."}"#.utf8)
                let task = Task { try await URLSession.shared.data(for: request) }
                await fixture.player.waitUntilPlaying()

                task.cancel()
                for _ in 0..<200 where await fixture.coordinator.hasActiveSession {
                    try await wait(for: .milliseconds(10))
                }
                let active = await fixture.coordinator.hasActiveSession
                let stops = await fixture.player.stopCount()
                try expect(!active, "a disconnected play client ends its reading")
                try expect(stops >= 1, "audio stops")
            }
        },
        TestCase(name: "play stops its reading when the client hangs up before playback starts") {
            let fixture = LiveFixture(player: APIAudioPlayer(blocking: true))
            _ = try await fixture.app.test(.live) { client in
                let port = try client.port.unwrap("live test port")
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/play")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(#"{"input":"Hang up early.","voice":"hold"}"#.utf8)
                let task = Task { try await URLSession.shared.data(for: request) }
                while await !fixture.manager.isHolding() {
                    try await wait(for: .milliseconds(2))
                }

                task.cancel()
                try await wait(for: .milliseconds(200))
                await fixture.manager.releaseHold()
                for _ in 0..<200 where await fixture.coordinator.hasActiveSession {
                    try await wait(for: .milliseconds(10))
                }
                let active = await fixture.coordinator.hasActiveSession
                try expect(!active, "a client that left during start does not keep its reading")
            }
        },
        TestCase(name: "stream upgrade accepts only its own loopback origin") {
            let fixture = LiveFixture()
            _ = try await fixture.app.test(.live) { client in
                let port = try client.port.unwrap("live test port")
                func upgradeStatus(origin: String) async throws -> Int {
                    try await rawHTTPStatus(
                        port: port,
                        request: "GET /v1/readback/stream HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
                            + "Origin: \(origin)\r\n\r\n"
                    )
                }
                for origin in ["http://127.0.0.1:5173", "https://evil.example"] {
                    let status = try await upgradeStatus(origin: origin)
                    try expect(status != 101, "\(origin) must not upgrade, got \(status)")
                }
                let own = try await upgradeStatus(origin: "http://127.0.0.1:51280")
                try expectEqual(own, 101, "ReadBack's own origin upgrades")
            }
        },
        TestCase(name: "a stream started while the model loads gets a clear error") {
            let fixture = LiveFixture(manager: APITestModelManager(runtimeState: .loading(.kokoro)))
            _ = try await fixture.app.test(.live) { client in
                try await client.ws("/v1/readback/stream") { inbound, _, _ in
                    var events = inbound.messages(maxSize: 65_536).makeAsyncIterator()
                    let error = try await nextEvent(&events, ofType: .error)
                    try expect(error.message?.contains("loading") == true, "loading message")
                }
            }
            let active = await fixture.coordinator.hasActiveSession
            try expect(!active, "no session starts while the model loads")
        },
    ]
}

private struct LiveFixture {
    let manager: APITestModelManager
    let player: APIAudioPlayer
    let coordinator: SpeechCoordinator
    let app: Application<RouterResponder<ReadBackRequestContext>>

    init(manager: APITestModelManager = APITestModelManager(), player: APIAudioPlayer = APIAudioPlayer()) {
        self.manager = manager
        self.player = player
        coordinator = SpeechCoordinator(synthesizer: manager, player: player)
        let router = ReadBackAPI(
            configuration: AppConfiguration.default(modelDirectory: URL(fileURLWithPath: "/tmp")),
            modelManager: manager,
            coordinator: coordinator
        ).makeRouter()
        app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
    }
}

private func send(_ event: ReadBackClientEvent, to outbound: WebSocketOutboundWriter) async throws {
    let data = try JSONEncoder().encode(event)
    try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
}

private func nextEvent(
    _ iterator: inout WebSocketInboundMessageStream.AsyncIterator,
    ofType type: ReadBackServerEvent.Kind
) async throws -> ReadBackServerEvent {
    for _ in 0..<20 {
        guard case .text(let text) = try await iterator.next() else { break }
        let event = try JSONDecoder().decode(ReadBackServerEvent.self, from: Data(text.utf8))
        if event.type == type { return event }
    }
    throw TestFailure(description: "missing \(type.rawValue) event")
}

private extension Optional {
    func unwrap(_ name: String) throws -> Wrapped {
        guard let self else { throw TestFailure(description: "missing \(name)") }
        return self
    }
}
