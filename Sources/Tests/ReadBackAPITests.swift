import Foundation
import Hummingbird
import HummingbirdTesting
import ReadBackCore
import ReadBackService

/// Plays instantly unless `blocking`, in which case each clip plays until it is
/// stopped or released.
actor APIAudioPlayer: AudioPlaying {
    private let blocking: Bool
    private var plays = 0
    private var stops = 0
    private var completion: CheckedContinuation<Void, Never>?
    private var playWaiters: [CheckedContinuation<Void, Never>] = []

    init(blocking: Bool = false) {
        self.blocking = blocking
    }

    func play(_ clip: AudioClip) async throws {
        plays += 1
        playWaiters.forEach { $0.resume() }
        playWaiters.removeAll()
        if blocking {
            await withCheckedContinuation { completion = $0 }
        }
    }

    func stop() async {
        stops += 1
        release()
    }

    func pause() async {}
    func resume() async {}

    func release() {
        completion?.resume()
        completion = nil
    }

    func waitUntilPlaying() async {
        if plays > 0 { return }
        await withCheckedContinuation { playWaiters.append($0) }
    }

    func stopCount() -> Int { stops }
    func playCount() -> Int { plays }
}

actor APITestModelManager: ModelManaging {
    private var requests: [SpeechRequest] = []
    private var runtimeState: ModelRuntimeState
    private let operation: ModelOperation
    private let failure: String?

    init(
        runtimeState: ModelRuntimeState = .ready(.kokoro),
        operation: ModelOperation = .idle,
        failure: String? = nil
    ) {
        self.runtimeState = runtimeState
        self.operation = operation
        self.failure = failure
    }

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
            runtimeState: runtimeState,
            operation: operation
        )
    }

    func updates() async -> AsyncStream<ModelManagerSnapshot> {
        AsyncStream { $0.finish() }
    }

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        requests.append(request)
        if let failure {
            throw TestFailure(description: failure)
        }
        return AudioClip(data: Data([0x01]), format: request.format)
    }

    func replayKey(for request: SpeechRequest) async throws -> SpeechReplayKey? {
        if request.voice == "missing" {
            throw ModelManagerError.invalidVoice("missing")
        }
        return nil
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

private struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }

    let error: Detail
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
            try await fixture.play(#"{"input":"hello"}"#, origin: "https://evil.example") { status, _ in
                try expectEqual(status, 403, "cross-origin play status")
            }
        },
        TestCase(name: "play answers bad input with 400 and a JSON error before interrupting") {
            let fixture = APIFixture()
            try await fixture.coordinator.replaceSession(id: "current") { _ in }
            let cases: [(body: String, code: String)] = [
                (#"{"input":"   \n "}"#, "empty_input"),
                (#"{"input":""}"#, "empty_input"),
                ("not json", "invalid_json"),
                (#"{"voice":"af_heart"}"#, "invalid_request"),
                (#"{"input":42}"#, "invalid_request"),
                (#"{"input":"hello","speed":9}"#, "invalid_speed"),
                (#"{"input":"hello","voice":"missing"}"#, "invalid_voice"),
                (#"{"input":"hello","model":"kokoro"}"#, "model_selection_not_allowed"),
            ]

            for testCase in cases {
                try await fixture.play(testCase.body) { status, error in
                    try expectEqual(status, 400, "status for \(testCase.body)")
                    try expectEqual(error?.code, testCase.code, "code for \(testCase.body)")
                    try expect(error?.message.isEmpty == false, "message for \(testCase.body)")
                }
            }
            let current = await fixture.coordinator.currentSessionID
            try expectEqual(current, "current", "bad requests leave the current reading alone")
        },
        TestCase(name: "play answers 503 while the model is loading") {
            let fixture = APIFixture(manager: APITestModelManager(runtimeState: .loading(.kokoro)))
            try await fixture.coordinator.replaceSession(id: "current") { _ in }

            try await fixture.play(#"{"input":"hello"}"#) { status, error in
                try expectEqual(status, 503, "loading status")
                try expectEqual(error?.code, "model_not_ready", "loading code")
                try expect(error?.message.contains("loading") == true, "loading message")
            }
            let current = await fixture.coordinator.currentSessionID
            try expectEqual(current, "current", "a rejected reading interrupts nothing")
        },
        TestCase(name: "play answers 503 during a model switch") {
            let fixture = APIFixture()
            try await fixture.gate.beginModelSwitch()

            try await fixture.play(#"{"input":"hello"}"#) { status, error in
                try expectEqual(status, 503, "switch status")
                try expectEqual(error?.code, "model_not_ready", "switch code")
                try expect(error?.message.contains("switching") == true, "switch message")
            }
            let gateState = await fixture.gate.currentState()
            try expectEqual(gateState, .modelSwitch, "switch keeps the gate")
        },
        TestCase(name: "play reads text longer than the queue limit in chunks") {
            let fixture = APIFixture()
            let sentence = "This sentence is part of a long reading. "
            let text = String(repeating: sentence, count: 120)
            let body = String(
                decoding: try JSONSerialization.data(withJSONObject: ["input": text]),
                as: UTF8.self
            )

            try await fixture.play(body) { status, _ in
                try expectEqual(status, 200, "long play status")
            }
            let requests = await fixture.manager.receivedRequests()
            let active = await fixture.coordinator.hasActiveSession
            let gateState = await fixture.gate.currentState()
            try expect(requests.count > 10, "text is split into chunks, got \(requests.count)")
            try expect(requests.allSatisfy { $0.input.count <= 250 }, "chunks stay short")
            try expectEqual(
                requests.map(\.input).joined(separator: " "),
                text.trimmingCharacters(in: .whitespaces),
                "every word is read in order"
            )
            try expect(!active, "no session is left behind")
            try expectEqual(gateState, .idle, "gate is released")
        },
        TestCase(name: "play splits paragraphs into separate segments") {
            let fixture = APIFixture()
            try await fixture.play(#"{"input":"First paragraph\n\nSecond paragraph"}"#) { status, _ in
                try expectEqual(status, 200, "paragraph play status")
            }
            let inputs = await fixture.manager.receivedRequests().map(\.input)
            try expectEqual(inputs, ["First paragraph", "Second paragraph"], "paragraph segments")
        },
        TestCase(name: "play reports a synthesis failure") {
            let fixture = APIFixture(manager: APITestModelManager(failure: "decoder crashed"))
            try await fixture.play(#"{"input":"hello"}"#) { status, error in
                try expectEqual(status, 500, "failure status")
                try expectEqual(error?.code, "speech_failed", "failure code")
                try expect(error?.message.contains("decoder crashed") == true, "failure message")
            }
        },
        TestCase(name: "play reports when a newer play replaced it") {
            let fixture = APIFixture(player: APIAudioPlayer(blocking: true))
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            try await app.test(.router) { client in
                async let first = client.execute(
                    uri: "/play",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"input":"first"}"#)
                )
                await fixture.player.waitUntilPlaying()
                let firstID = await fixture.coordinator.currentSessionID

                let secondTask = Task {
                    try await client.execute(
                        uri: "/play",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: ByteBuffer(string: #"{"input":"second"}"#)
                    )
                }
                let firstResponse = try await first
                let error = try JSONDecoder().decode(ErrorBody.self, from: firstResponse.body)
                try expectEqual(firstResponse.status.code, 409, "replaced play status")
                try expectEqual(error.error.code, "interrupted", "replaced play code")

                while await fixture.coordinator.currentSessionID == firstID {
                    try await wait(for: .milliseconds(2))
                }
                while await fixture.player.playCount() < 2 {
                    try await wait(for: .milliseconds(2))
                }
                await fixture.player.release()
                let secondResponse = try await secondTask.value
                try expectEqual(secondResponse.status.code, 200, "newer play status")
            }
        },
        TestCase(name: "play reports when the app stopped it") {
            let fixture = APIFixture(player: APIAudioPlayer(blocking: true))
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            try await app.test(.router) { client in
                async let response = client.execute(
                    uri: "/play",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"input":"stop me"}"#)
                )
                await fixture.player.waitUntilPlaying()
                await fixture.coordinator.stop()

                let stopped = try await response
                let error = try JSONDecoder().decode(ErrorBody.self, from: stopped.body)
                try expectEqual(stopped.status.code, 409, "stopped play status")
                try expectEqual(error.error.code, "stopped", "stopped play code")
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
    let player: APIAudioPlayer
    let gate: ReadBackActivityGate
    let coordinator: SpeechCoordinator
    let api: ReadBackAPI

    init(manager: APITestModelManager = APITestModelManager(), player: APIAudioPlayer = APIAudioPlayer()) {
        self.manager = manager
        self.player = player
        gate = ReadBackActivityGate()
        let configuration = AppConfiguration.default(
            modelDirectory: URL(fileURLWithPath: "/tmp")
        )
        coordinator = SpeechCoordinator(
            synthesizer: manager,
            player: player,
            activityGate: gate
        )
        api = ReadBackAPI(
            configuration: configuration,
            modelManager: manager,
            coordinator: coordinator
        )
    }

    func play(
        _ body: String,
        origin: String? = nil,
        check: @escaping @Sendable (Int, ErrorBody.Detail?) throws -> Void
    ) async throws {
        let app = Application(responder: api.makeRouter().buildResponder())
        var headers: HTTPFields = [.contentType: "application/json"]
        if let origin {
            headers[.origin] = origin
        }
        try await app.test(.router) { [headers] client in
            try await client.execute(
                uri: "/play",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: body)
            ) { response in
                let error = try? JSONDecoder().decode(ErrorBody.self, from: response.body)
                try check(Int(response.status.code), error?.error)
            }
        }
    }
}
