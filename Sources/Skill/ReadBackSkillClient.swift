import Foundation

public protocol ReadBackSkillTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public protocol ReadBackAppLaunching: Sendable {
    func launch() async throws
}

public protocol ReadBackSkillClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousReadBackSkillClock: ReadBackSkillClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        let clock = ContinuousClock()
        try await clock.sleep(until: clock.now.advanced(by: duration))
    }
}

public final class URLSessionReadBackSkillTransport: ReadBackSkillTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ReadBackSkillClientError.invalidResponse
        }
        return (data, response)
    }
}

public enum ReadBackSkillClientError: LocalizedError, Sendable {
    case argumentsNotAllowed
    case emptyInput
    case invalidInputEncoding
    case invalidResponse
    case serviceNotReady
    case unexpectedStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .argumentsNotAllowed:
            "Pass spoken text through standard input; command options are not supported."
        case .emptyInput:
            "The spoken brief is empty."
        case .invalidInputEncoding:
            "The spoken brief must use UTF-8."
        case .invalidResponse:
            "ReadBack returned an invalid response."
        case .serviceNotReady:
            "ReadBack did not become ready for speech."
        case .unexpectedStatus(let status, let message):
            message.isEmpty
                ? "ReadBack returned HTTP \(status)."
                : "ReadBack returned HTTP \(status): \(message)"
        }
    }
}

public enum ReadBackSkillCommandInput {
    public static func parse(arguments: [String], data: Data) throws -> String {
        guard arguments.isEmpty else {
            throw ReadBackSkillClientError.argumentsNotAllowed
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReadBackSkillClientError.invalidInputEncoding
        }
        return text
    }
}

public struct ReadBackSkillClient: Sendable {
    public static let localBaseURL = URL(string: "http://127.0.0.1:51280")!

    private struct Health: Decodable {
        let runtime: String
        let modelInstalled: Bool

        private enum CodingKeys: String, CodingKey {
            case runtime
            case modelInstalled = "model_installed"
        }

        var isReady: Bool {
            runtime == "ready" && modelInstalled
        }
    }

    private struct PlayRequest: Encodable {
        let input: String
    }

    private let baseURL: URL
    private let transport: any ReadBackSkillTransport
    private let launcher: any ReadBackAppLaunching
    private let clock: any ReadBackSkillClock
    private let readinessAttempts: Int
    private let readinessPollInterval: Duration

    public init(
        baseURL: URL = ReadBackSkillClient.localBaseURL,
        transport: any ReadBackSkillTransport,
        launcher: any ReadBackAppLaunching,
        clock: any ReadBackSkillClock = ContinuousReadBackSkillClock(),
        readinessAttempts: Int = 450,
        readinessPollInterval: Duration = .milliseconds(200)
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.launcher = launcher
        self.clock = clock
        self.readinessAttempts = max(1, readinessAttempts)
        self.readinessPollInterval = readinessPollInterval
    }

    public func play(_ text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadBackSkillClientError.emptyInput
        }

        do {
            if try await serviceIsReady() {
                try await sendPlayRequest(text)
                return
            }
            try await waitUntilReady(startingAtAttempt: 1)
        } catch let error as URLError where Self.isConnectionFailure(error) {
            try await launcher.launch()
            try await waitUntilReady(startingAtAttempt: 0)
        }

        try await sendPlayRequest(text)
    }

    private func waitUntilReady(startingAtAttempt firstAttempt: Int) async throws {
        guard firstAttempt < readinessAttempts else {
            throw ReadBackSkillClientError.serviceNotReady
        }

        for attempt in firstAttempt..<readinessAttempts {
            if attempt > 0 {
                try await clock.sleep(for: readinessPollInterval)
            }
            do {
                if try await serviceIsReady() {
                    return
                }
            } catch let error as URLError where Self.isConnectionFailure(error) {
                continue
            }
        }
        throw ReadBackSkillClientError.serviceNotReady
    }

    private func serviceIsReady() async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ReadBackSkillClientError.unexpectedStatus(
                response.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else {
            throw ReadBackSkillClientError.invalidResponse
        }
        return health.isReady
    }

    private func sendPlayRequest(_ text: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("play"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PlayRequest(input: text))
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ReadBackSkillClientError.unexpectedStatus(
                response.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
    }

    private static func isConnectionFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
             .timedOut:
            true
        default:
            false
        }
    }
}
