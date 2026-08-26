import Foundation

public protocol ClipboardSpeechPlaying: Sendable {
    func cancel() async
    func speak(_ text: String) async throws
}

public enum ClipboardReadBackError: Error, Equatable, Sendable {
    case noText
    case tooLong(actual: Int, maximum: Int)
}

public enum ClipboardReadBackResult: Equatable, Sendable {
    case spoken(characterCount: Int)
}

public struct ClipboardReadBackAction: Sendable {
    private let speaker: any ClipboardSpeechPlaying
    private let maximumCharacters: Int

    public init(speaker: any ClipboardSpeechPlaying, maximumCharacters: Int) {
        precondition(maximumCharacters > 0)
        self.speaker = speaker
        self.maximumCharacters = maximumCharacters
    }

    public func validatedText(from text: String?) throws -> String {
        guard let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else {
            throw ClipboardReadBackError.noText
        }
        guard normalized.count <= maximumCharacters else {
            throw ClipboardReadBackError.tooLong(
                actual: normalized.count,
                maximum: maximumCharacters
            )
        }
        return normalized
    }

    public func perform(text: String?) async throws -> ClipboardReadBackResult {
        let normalized = try validatedText(from: text)
        await speaker.cancel()
        try Task.checkCancellation()
        try await speaker.speak(normalized)
        return .spoken(characterCount: normalized.count)
    }
}
