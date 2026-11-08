import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import ReadBackCore
import ReadBackService

private actor HistoryTestModelManager: ModelManaging {
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
        AudioClip(data: Data([0x01]), format: request.format)
    }

    func install(_ id: ModelID) async throws {}
    func installLanguage(_ code: String, for id: ModelID) async throws {}
    func registerLocalModel(at directory: URL) async throws -> ModelID { .local }
    func remove(_ id: ModelID) async throws {}
    func activate(_ id: ModelID) async throws {}
    func updatePreferences(_ preferences: ModelPreference) async throws {}
    func warmConfiguredModel() async {}
}

private actor HistoryTestAudioPlayer: AudioPlaying {
    private let playDuration: Duration

    init(playDuration: Duration = .zero) {
        self.playDuration = playDuration
    }

    func play(_ clip: AudioClip) async throws {
        try await wait(for: playDuration)
    }

    func stop() async {}
    func pause() async {}
    func resume() async {}
}

private struct HistoryAPIFixture {
    let api: ReadBackAPI
    let store: HistoryStore

    init(historyFile: URL, playDuration: Duration = .zero) {
        let manager = HistoryTestModelManager()
        store = HistoryStore(fileURL: historyFile)
        api = ReadBackAPI(
            configuration: AppConfiguration.default(modelDirectory: URL(fileURLWithPath: "/tmp")),
            modelManager: manager,
            coordinator: SpeechCoordinator(
                synthesizer: manager,
                player: HistoryTestAudioPlayer(playDuration: playDuration)
            ),
            history: HistoryRecorder(store: store)
        )
    }

    /// Opens a stream at `path`, sends `events`, and returns once the session finishes.
    func stream(path: String, events: [ReadBackClientEvent]) async throws {
        let router = api.makeRouter()
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        _ = try await app.test(.live) { client in
            try await client.ws(path) { inbound, outbound, _ in
                let encoder = JSONEncoder()
                let decoder = JSONDecoder()
                var iterator = inbound.messages(maxSize: 65_536).makeAsyncIterator()
                guard case .text = try await iterator.next() else {
                    throw TestFailure(description: "missing session ready event")
                }
                for event in events {
                    let data = try encoder.encode(event)
                    try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                }
                while case .text(let text) = try await iterator.next() {
                    let event = try decoder.decode(ReadBackServerEvent.self, from: Data(text.utf8))
                    if event.type == .sessionFinished { return }
                    if event.type == .error {
                        throw TestFailure(description: "stream error: \(event.message ?? "")")
                    }
                }
                throw TestFailure(description: "stream closed before the session finished")
            }
        }
    }
}

func historyRecordingAPITests() -> [TestCase] {
    [
        TestCase(name: "play saves an agent entry with the reported host") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = HistoryAPIFixture(historyFile: file)
            let app = Application(responder: fixture.api.makeRouter().buildResponder())
            let clientHeader = HTTPField.Name("X-ReadBack-Client")!

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/play",
                    method: .post,
                    headers: [.contentType: "application/json", clientHeader: "Cursor"],
                    body: ByteBuffer(string: #"{"input":"From Cursor."}"#)
                ) { response in
                    try expectEqual(response.status.code, 200, "play with host status")
                }
                try await client.execute(
                    uri: "/play",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"input":"From an unnamed agent."}"#)
                ) { response in
                    try expectEqual(response.status.code, 200, "play without host status")
                }
            }

            let entries = try await fixture.store.entries()
            try expectEqual(
                entries.map(\.text),
                ["From an unnamed agent.", "From Cursor."],
                "agent texts"
            )
            try expectEqual(
                entries.map(\.source),
                [.agent(host: nil), .agent(host: "Cursor")],
                "agent sources"
            )
        },
        TestCase(name: "play keeps working when history is unavailable") {
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = HistoryAPIFixture(historyFile: file)
            let app = Application(responder: fixture.api.makeRouter().buildResponder())

            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/play",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"input":"Spoken anyway."}"#)
                ) { response in
                    try expectEqual(response.status.code, 200, "play status without history")
                }
            }
        },
        TestCase(name: "a voicepipe stream is saved as one growing entry") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = HistoryAPIFixture(historyFile: file)

            try await fixture.stream(
                path: "/v1/readback/stream",
                events: [.textAppend("First sentence. "), .textAppend("Second sentence."), .inputDone]
            )

            let entries = try await fixture.store.entries()
            try expectEqual(entries.map(\.text), ["First sentence. Second sentence."], "streamed text")
            try expectEqual(entries.map(\.source), [.voicepipe], "streamed source")
        },
        TestCase(name: "a cancelled stream keeps the text sent before cancelling") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = HistoryAPIFixture(historyFile: file, playDuration: .seconds(5))

            try await fixture.stream(
                path: "/v1/readback/stream",
                events: [.textAppend("Interrupted reading."), .inputCommit, .playbackCancel]
            )

            let entries = try await fixture.store.entries()
            try expectEqual(entries.map(\.text), ["Interrupted reading."], "interrupted text")
        },
        TestCase(name: "the app's own stream endpoint is not saved by the server") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = HistoryAPIFixture(historyFile: file)
            guard let url = ReadBackAPI.historySkippingStreamURL(host: "127.0.0.1", port: 51_280),
                  let query = url.query
            else {
                throw TestFailure(description: "invalid app stream URL")
            }

            try await fixture.stream(
                path: "\(url.path)?\(query)",
                events: [.textAppend("test, hello world"), .inputDone]
            )

            let entries = try await fixture.store.entries()
            try expectEqual(entries, [], "no server-side entry")
        },
    ]
}
