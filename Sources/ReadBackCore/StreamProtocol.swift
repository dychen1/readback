import Foundation

public enum ReadBackClientEvent: Codable, Equatable, Sendable {
    case textAppend(String)
    case inputCommit
    case inputDone
    case playbackCancel
    case playbackPause
    case playbackResume

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    private enum Kind: String, Codable {
        case textAppend = "text.append"
        case inputCommit = "input.commit"
        case inputDone = "input.done"
        case playbackCancel = "playback.cancel"
        case playbackPause = "playback.pause"
        case playbackResume = "playback.resume"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .textAppend:
            self = .textAppend(try container.decode(String.self, forKey: .text))
        case .inputCommit:
            self = .inputCommit
        case .inputDone:
            self = .inputDone
        case .playbackCancel:
            self = .playbackCancel
        case .playbackPause:
            self = .playbackPause
        case .playbackResume:
            self = .playbackResume
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textAppend(let text):
            try container.encode(Kind.textAppend, forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputCommit:
            try container.encode(Kind.inputCommit, forKey: .type)
        case .inputDone:
            try container.encode(Kind.inputDone, forKey: .type)
        case .playbackCancel:
            try container.encode(Kind.playbackCancel, forKey: .type)
        case .playbackPause:
            try container.encode(Kind.playbackPause, forKey: .type)
        case .playbackResume:
            try container.encode(Kind.playbackResume, forKey: .type)
        }
    }
}

public struct ReadBackServerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case sessionReady = "session.ready"
        case speechQueued = "speech.queued"
        case speechStarted = "speech.started"
        case speechFinished = "speech.finished"
        case queuePaused = "queue.paused"
        case queueResumed = "queue.resumed"
        case sessionFinished = "session.finished"
        case playbackPaused = "playback.paused"
        case playbackResumed = "playback.resumed"
        case error
    }

    public let type: Kind
    public let sessionID: String
    public let sequence: Int?
    public let message: String?

    public init(type: Kind, sessionID: String, sequence: Int? = nil, message: String? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.sequence = sequence
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case sequence
        case message
    }
}
