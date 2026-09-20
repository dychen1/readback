import Foundation

public struct ReplayableSpeech: Sendable {
    public let clip: AudioClip
    public let key: SpeechReplayKey?

    public init(clip: AudioClip, key: SpeechReplayKey?) {
        self.clip = clip
        self.key = key
    }
}

/// The resolved request and loaded model generation that produced an audio clip.
public struct SpeechReplayKey: Equatable, Sendable {
    public let modelID: ModelID
    public let modelGeneration: UInt64
    public let request: SpeechRequest

    public init(modelID: ModelID, modelGeneration: UInt64, request: SpeechRequest) {
        self.modelID = modelID
        self.modelGeneration = modelGeneration
        self.request = request
    }
}

/// Retains one completed reading, including all its audio chunks. A recording
/// token prevents work finishing after invalidation from restoring discarded data.
public struct SpeechReplayCache: Sendable {
    // About six minutes of 24 kHz float audio. Longer readings still play, but
    // are not retained. The bound includes text as well as encoded audio.
    public static let defaultMaximumBytes = 32 * 1024 * 1024

    private struct Segment: Sendable {
        let key: SpeechReplayKey
        let clip: AudioClip
    }

    private struct Recording: Sendable {
        let id: UUID
        var segments: [Segment]? = []
        var bytes = 0
    }

    private let maximumBytes: Int
    private var completed: [Segment]?
    private var recording: Recording?

    public init(maximumBytes: Int = defaultMaximumBytes) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    public mutating func beginRecording() -> UUID {
        let id = UUID()
        recording = Recording(id: id)
        return id
    }

    public func clip(at index: Int, matching key: SpeechReplayKey) -> AudioClip? {
        guard let completed, completed.indices.contains(index), completed[index].key == key else {
            return nil
        }
        return completed[index].clip
    }

    public mutating func record(_ clip: AudioClip, key: SpeechReplayKey, recordingID: UUID) {
        guard recording?.id == recordingID, recording?.segments != nil else { return }
        let bytes = clip.data.count + key.request.input.utf8.count
        guard bytes <= maximumBytes - (recording?.bytes ?? 0) else {
            recording?.segments = nil
            recording?.bytes = 0
            return
        }
        recording?.segments?.append(Segment(key: key, clip: clip))
        recording?.bytes += bytes
    }

    public mutating func complete(recordingID: UUID) {
        guard let recording, recording.id == recordingID else { return }
        completed = recording.segments
        self.recording = nil
    }

    public mutating func abort(recordingID: UUID) {
        guard recording?.id == recordingID else { return }
        recording = nil
    }

    public mutating func invalidate() {
        completed = nil
        recording = nil
    }
}
