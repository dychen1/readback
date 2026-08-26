import Foundation

public struct LocalServiceHealth: Decodable, Equatable, Sendable {
    public let status: String
    public let backend: String
    public let modelInstalled: Bool

    public var isReadyForSpeech: Bool {
        status == "ok" && backend == "ready" && modelInstalled
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case backend
        case modelInstalled = "model_installed"
    }
}
