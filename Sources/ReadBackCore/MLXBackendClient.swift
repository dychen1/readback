import Foundation

public enum MLXBackendError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
}

public final class MLXBackendClient: SpeechSynthesizing, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder

    public convenience init(baseURL: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        self.init(baseURL: baseURL, session: URLSession(configuration: configuration))
    }

    public init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
    }

    public func isHealthy() async -> Bool {
        do {
            var request = URLRequest(url: endpoint(""))
            request.httpMethod = "GET"
            _ = try await perform(request)
            return true
        } catch {
            return false
        }
    }

    public func loadModel(at modelPath: URL) async throws {
        var components = URLComponents(
            url: endpoint("v1/models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "model_name", value: modelPath.path)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        _ = try await perform(request)
    }

    public func isModelLoaded(at modelPath: URL) async -> Bool {
        do {
            var request = URLRequest(url: endpoint("v1/models"))
            request.httpMethod = "GET"
            let response = try JSONDecoder().decode(
                BackendModelList.self,
                from: try await perform(request)
            )
            return response.data.contains { $0.id == modelPath.path }
        } catch {
            return false
        }
    }

    public func synthesize(_ request: SpeechRequest, modelPath: URL) async throws -> AudioClip {
        let payload = BackendSpeechRequest(
            model: modelPath.path,
            input: request.input,
            voice: resolvedVoice(request.voice, modelPath: modelPath),
            languageCode: request.languageCode,
            responseFormat: request.format,
            speed: request.speed
        )
        var urlRequest = URLRequest(url: endpoint("v1/audio/speech"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(payload)
        return AudioClip(data: try await perform(urlRequest), format: request.format)
    }

    private func resolvedVoice(_ voice: String, modelPath: URL) -> String {
        guard !voice.contains("/") else { return voice }
        let localVoice = modelPath
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent("\(voice).safetensors")
        guard FileManager.default.fileExists(atPath: localVoice.path) else { return voice }
        return localVoice.path
    }

    private func endpoint(_ path: String) -> URL {
        guard !path.isEmpty else {
            return baseURL.appendingPathComponent("")
        }
        return baseURL.appendingPathComponent(path)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MLXBackendError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MLXBackendError.httpStatus(
                response.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}

private struct BackendSpeechRequest: Encodable {
    let model: String
    let input: String
    let voice: String
    let languageCode: String
    let responseFormat: AudioFormat
    let speed: Double

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case languageCode = "lang_code"
        case responseFormat = "response_format"
        case speed
    }
}

private struct BackendModelList: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
