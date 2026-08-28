import Foundation

public struct LocalServiceHealth: Decodable, Equatable, Sendable {
    public let status: String
    public let runtime: String
    public let activeModel: String?
    public let modelInstalled: Bool

    public var isReadyForSpeech: Bool {
        status == "ok" && runtime == "ready" && activeModel != nil && modelInstalled
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case runtime
        case activeModel = "active_model"
        case modelInstalled = "model_installed"
    }
}
