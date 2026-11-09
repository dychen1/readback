import Foundation

public struct ReadingRequest: Equatable, Sendable {
    public let text: String
    public let voice: String?
    public let languageCode: String?
    public let speed: Double?

    public init(text: String, voice: String? = nil, languageCode: String? = nil, speed: Double? = nil) {
        self.text = text
        self.voice = voice
        self.languageCode = languageCode
        self.speed = speed
    }
}

/// Why a reading could not start. Nothing that was already playing is interrupted.
public enum ReadingStartError: Error, Equatable, Sendable {
    case emptyText
    case speedOutOfRange(Double)
    case invalidVoice(String)
    case modelUnavailable(String)

    public static let speedRange = PlaybackRate.minimum...PlaybackRate.maximum

    /// Whether the caller can fix the request. If not, ReadBack is not ready.
    public var isInvalidRequest: Bool {
        if case .modelUnavailable = self { return false }
        return true
    }

    public var message: String {
        switch self {
        case .emptyText:
            "The text to read is empty."
        case .speedOutOfRange(let speed):
            "Speed \(speed) is outside the supported range "
                + "\(Self.speedRange.lowerBound)–\(Self.speedRange.upperBound)."
        case .invalidVoice(let voice):
            "The active model has no voice named \"\(voice)\"."
        case .modelUnavailable(let reason):
            reason
        }
    }
}

/// Validates a one-shot reading, makes it the current reading, and queues its text
/// in paragraph-aware chunks.
public struct ReadingStarter: Sendable {
    private let coordinator: SpeechCoordinator
    private let modelManager: any ModelManaging
    private let speechSettings: SpeechSettingsStore

    public init(
        coordinator: SpeechCoordinator,
        modelManager: any ModelManaging,
        speechSettings: SpeechSettingsStore
    ) {
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.speechSettings = speechSettings
    }

    /// Starts `request` and returns its session ID once it is the current reading.
    /// Its text keeps queuing in the background, so this returns before playback
    /// finishes. Throws `ReadingStartError` before touching the current reading.
    public func start(_ request: ReadingRequest) async throws(ReadingStartError) -> String {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyText }
        if let speed = request.speed, !ReadingStartError.speedRange.contains(speed) {
            throw .speedOutOfRange(speed)
        }
        if let unavailable = await unavailableReason() {
            throw .modelUnavailable(unavailable)
        }
        let defaults = await currentSettings()
        let settings = SpeechSettings(
            voice: request.voice ?? defaults.voice,
            languageCode: request.languageCode ?? defaults.languageCode,
            synthesisSpeed: request.speed ?? defaults.synthesisSpeed,
            paragraphPause: defaults.paragraphPause
        )
        do {
            _ = try await modelManager.replayKey(
                for: SpeechRequest(
                    input: text,
                    voice: settings.voice,
                    languageCode: settings.languageCode,
                    speed: settings.synthesisSpeed,
                    format: .wav
                )
            )
        } catch ModelManagerError.invalidVoice(let voice) {
            throw .invalidVoice(voice)
        } catch {
            throw .modelUnavailable(Self.notReadyMessage)
        }

        let id = UUID().uuidString
        do {
            try await coordinator.replaceSession(id: id) { _ in }
        } catch {
            throw .modelUnavailable(Self.switchingMessage)
        }
        Task { [coordinator] in
            var chunker = StreamingTextChunker()
            let chunks = chunker.append(text) + (chunker.flush().map { [$0] } ?? [])
            do {
                _ = try await coordinator.enqueueWaitingForRoom(
                    chunks,
                    sessionID: id,
                    settings: settings,
                    pauseBefore: 0
                )
                await coordinator.finishInput(sessionID: id)
            } catch {
                await coordinator.cancel(sessionID: id)
            }
        }
        return id
    }

    /// Explains why speech cannot start right now, or returns `nil` when it can.
    public func unavailableReason() async -> String? {
        let snapshot = await modelManager.snapshot()
        switch snapshot.runtimeState {
        case .starting, .loading:
            return "The voice model is still loading. Try again in a few seconds."
        case .unloading:
            return Self.switchingMessage
        case .failed(_, let message):
            return "The voice model failed to load (\(message)). Choose a model in ReadBack."
        case .ready:
            return snapshot.operation == .idle ? nil : Self.busyMessage
        }
    }

    /// The voice, speed, and paragraph pause a reading uses when its request does not
    /// override them.
    public func currentSettings() async -> SpeechSettings {
        let snapshot = await modelManager.snapshot()
        let playbackSettings = await speechSettings.current()
        return SpeechSettings(
            voice: snapshot.activePreferences?.voiceID,
            languageCode: nil,
            synthesisSpeed: snapshot.activePreferences?.synthesisSpeed ?? 1,
            paragraphPause: playbackSettings.paragraphPause
        )
    }

    public static let switchingMessage =
        "ReadBack is switching voice models. Try again when the model is loaded."
    private static let busyMessage =
        "ReadBack is installing or switching a model. Try again when it finishes."
    private static let notReadyMessage = "The voice model is not ready. Try again in a few seconds."
}
