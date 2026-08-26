import Foundation

public enum AudioFormat: String, Codable, Equatable, Sendable {
    case wav
    case pcm
}

public struct SpeechRequest: Codable, Equatable, Sendable {
    public let input: String
    public let voice: String
    public let speed: Double
    public let format: AudioFormat

    public init(input: String, voice: String, speed: Double, format: AudioFormat) {
        self.input = input
        self.voice = voice
        self.speed = speed
        self.format = format
    }
}

public struct AudioClip: Equatable, Sendable {
    public let data: Data
    public let format: AudioFormat

    public init(data: Data, format: AudioFormat) {
        self.data = data
        self.format = format
    }
}

public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ request: SpeechRequest, modelPath: URL) async throws -> AudioClip
}
