import Foundation
import ReadBackCore

func mlxBackendClientTests() -> [TestCase] {
    [
        TestCase(name: "backend health calls the MLX root endpoint") {
            let fixture = makeBackendFixture { request in
                try expectEqual(request.httpMethod, "GET", "health method")
                try expectEqual(request.url?.path, "/", "health path")
                return StubResponse(status: 200, body: Data(#"{"message":"ok"}"#.utf8))
            }

            let healthy = await fixture.client.isHealthy()
            try expect(healthy, "backend should be healthy")
        },
        TestCase(name: "backend load passes the exact local model path") {
            let fixture = makeBackendFixture { request in
                try expectEqual(request.httpMethod, "POST", "load method")
                try expectEqual(request.url?.path, "/v1/models", "load path")
                let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                try expectEqual(
                    components?.queryItems?.first(where: { $0.name == "model_name" })?.value,
                    "/tmp/read back/models/Kokoro-82M-bf16",
                    "local model query"
                )
                return StubResponse(status: 200, body: Data(#"{"status":"success"}"#.utf8))
            }

            try await fixture.client.loadModel(
                at: URL(fileURLWithPath: "/tmp/read back/models/Kokoro-82M-bf16")
            )
        },
        TestCase(name: "backend reports whether the exact local model is loaded") {
            let fixture = makeBackendFixture { request in
                try expectEqual(request.httpMethod, "GET", "models method")
                try expectEqual(request.url?.path, "/v1/models", "models path")
                return StubResponse(
                    status: 200,
                    body: Data(
                        #"{"data":[{"id":"/tmp/models/Kokoro-82M-bf16"}]}"#.utf8
                    )
                )
            }

            let loaded = await fixture.client.isModelLoaded(
                at: URL(fileURLWithPath: "/tmp/models/Kokoro-82M-bf16")
            )
            try expect(loaded, "exact local model should be loaded")
        },
        TestCase(name: "speech request uses local model path and returns WAV bytes") {
            let expectedAudio = Data([0x52, 0x49, 0x46, 0x46])
            let fixture = makeBackendFixture { request in
                try expectEqual(request.httpMethod, "POST", "speech method")
                try expectEqual(request.url?.path, "/v1/audio/speech", "speech path")
                let body = try expectJSONBody(request)
                try expectEqual(
                    body["model"] as? String,
                    "/tmp/models/Kokoro-82M-bf16",
                    "speech model"
                )
                try expectEqual(body["input"] as? String, "Hello", "speech input")
                try expectEqual(body["voice"] as? String, "af_heart", "speech voice")
                try expectEqual(body["response_format"] as? String, "wav", "speech format")
                try expectEqual(body["speed"] as? Double, 1.1, "speech speed")
                return StubResponse(status: 200, body: expectedAudio, contentType: "audio/wav")
            }

            let clip = try await fixture.client.synthesize(
                SpeechRequest(input: "Hello", voice: "af_heart", speed: 1.1, format: .wav),
                modelPath: URL(fileURLWithPath: "/tmp/models/Kokoro-82M-bf16")
            )

            try expectEqual(clip.data, expectedAudio, "audio bytes")
            try expectEqual(clip.format, .wav, "audio format")
        },
        TestCase(name: "speech request resolves an installed voice without network access") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let voices = root.appendingPathComponent("voices", isDirectory: true)
            try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
            let voice = voices.appendingPathComponent("af_heart.safetensors")
            try Data([0x01]).write(to: voice)
            let fixture = makeBackendFixture { request in
                let body = try expectJSONBody(request)
                try expectEqual(body["voice"] as? String, voice.path, "local voice path")
                return StubResponse(status: 200, body: Data([0x52, 0x49, 0x46, 0x46]))
            }

            _ = try await fixture.client.synthesize(
                SpeechRequest(input: "Hello", voice: "af_heart", speed: 1, format: .wav),
                modelPath: root
            )
        },
        TestCase(name: "backend exposes upstream status and body") {
            let fixture = makeBackendFixture { _ in
                StubResponse(status: 503, body: Data("warming".utf8))
            }

            do {
                _ = try await fixture.client.synthesize(
                    SpeechRequest(input: "Hello", voice: "af_heart", speed: 1, format: .wav),
                    modelPath: URL(fileURLWithPath: "/tmp/model")
                )
                throw TestFailure(description: "upstream error should throw")
            } catch let error as MLXBackendError {
                try expectEqual(error, .httpStatus(503, "warming"), "upstream error")
            }
        },
    ]
}

private struct BackendFixture {
    let client: MLXBackendClient
}

private struct StubResponse {
    let status: Int
    let body: Data
    let contentType: String

    init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }
}

private func makeBackendFixture(
    handler: @escaping (URLRequest) throws -> StubResponse
) -> BackendFixture {
    StubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return BackendFixture(
        client: MLXBackendClient(
            baseURL: URL(string: "http://127.0.0.1:51281")!,
            session: session
        )
    )
}

private func expectJSONBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try request.httpBody ?? request.httpBodyStream.map(readAllBytes)
    guard let data,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure(description: "request needs a JSON object body")
    }
    return object
}

private func readAllBytes(from stream: InputStream) throws -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? TestFailure(description: "request body stream failed")
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw TestFailure(description: "stub handler is missing")
            }
            let response = try handler(request)
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": response.contentType]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
