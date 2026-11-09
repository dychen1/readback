import Foundation
import os

/// All speech paths use this type to add entries to history.
///
/// Recording does not throw. If a save fails, the recorder writes the error to the system log
/// and the reading continues.
public struct HistoryRecorder: Sendable {
    public let store: HistoryStore
    private let now: @Sendable () -> Date
    private static let logger = Logger(subsystem: "ai.sanrin.readback", category: "history")

    public init(store: HistoryStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Saves a reading that has just started. Returns the ID of the new entry. Returns `nil`
    /// if the text is blank or the save fails.
    ///
    /// The entry does not keep leading whitespace. Playback chunk offsets start at the first
    /// character that is not whitespace, so they then point into the stored text.
    @discardableResult
    public func record(_ text: String, source: HistorySource) async -> Int64? {
        let text = String(text.drop(while: \.isWhitespace))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try await store.insert(text, source: source, at: now())
        } catch {
            Self.logger.error(
                "History did not save an entry. \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    public func stream(source: HistorySource) -> HistoryStreamRecording {
        HistoryStreamRecording(recorder: self, source: source)
    }

    fileprivate func append(_ text: String, to id: Int64) async -> Bool {
        do {
            try await store.append(text, to: id)
            return true
        } catch {
            Self.logger.error(
                "History did not add text to entry \(id). \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

/// Records one streamed reading. It creates the entry when the first non-blank text arrives,
/// then adds each later piece of text. An interrupted stream keeps all text sent before the stop.
public struct HistoryStreamRecording: Sendable {
    public static let disabled = HistoryStreamRecording(recorder: nil, source: .voicepipe)

    private let recorder: HistoryRecorder?
    private let source: HistorySource
    private var entryID: Int64?
    private var isFinished = false

    fileprivate init(recorder: HistoryRecorder?, source: HistorySource) {
        self.recorder = recorder
        self.source = source
    }

    /// Adds `text` to the entry. Returns the ID of the entry only when this call creates it.
    @discardableResult
    public mutating func append(_ text: String) async -> Int64? {
        guard let recorder, !isFinished, !text.isEmpty else { return nil }
        if let entryID {
            // Stop after a failed append, for example after the user deletes the entry. An
            // entry with a gap would replay text that is different from what the user heard.
            let appended = await recorder.append(text, to: entryID)
            isFinished = !appended
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        entryID = await recorder.record(text, source: source)
        isFinished = entryID == nil
        return entryID
    }

    /// Ends the recording. The recording ignores all later text.
    public mutating func finish() {
        isFinished = true
    }
}

/// Tells why the app speaks. Only clipboard reads become history entries. The user did not
/// ask to hear a preview. A replay or a restart repeats an entry that history already has.
public enum AppSpeechPurpose: Equatable, Sendable {
    case clipboardRead
    case voicePreview
    case historyReplay(HistoryEntry.ID)
    /// Starts the current reading again after a settings change. The value is the history
    /// entry of that reading, if it has one.
    case settingsRestart(HistoryEntry.ID?)
}

extension HistoryRecorder {
    /// Returns the history entry of a reading that the app starts. A clipboard read becomes a
    /// new entry. A replay or a restart uses the entry that it repeats. A voice preview has no
    /// entry.
    public func entryID(for purpose: AppSpeechPurpose, text: String) async -> HistoryEntry.ID? {
        switch purpose {
        case .clipboardRead: await record(text, source: .clipboard)
        case .voicePreview: nil
        case .historyReplay(let id): id
        case .settingsRestart(let id): id
        }
    }
}

extension HistorySource {
    public static let maximumAgentHostLength = 64

    /// Makes an agent source from the host name that a client sends. The name is optional,
    /// and ReadBack does not trust it.
    public static func agent(reportedHost: String?) -> HistorySource {
        let printable = (reportedHost ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let host = String(String.UnicodeScalarView(printable))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumAgentHostLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .agent(host: host.isEmpty ? nil : host)
    }
}
