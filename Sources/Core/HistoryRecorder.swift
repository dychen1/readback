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
    @discardableResult
    public func record(_ text: String, source: HistorySource) async -> Int64? {
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

    public mutating func append(_ text: String) async {
        guard let recorder, !isFinished, !text.isEmpty else { return }
        if let entryID {
            // Stop after a failed append, for example after the user deletes the entry. An
            // entry with a gap would replay text that is different from what the user heard.
            let appended = await recorder.append(text, to: entryID)
            isFinished = !appended
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entryID = await recorder.record(text, source: source)
            isFinished = entryID == nil
        }
    }

    /// Ends the recording. The recording ignores all later text.
    public mutating func finish() {
        isFinished = true
    }
}

/// Tells why the app speaks. Only clipboard reads become history entries. The user did not
/// ask to hear a preview. A replay or a restart repeats an entry that history already has.
public enum AppSpeechPurpose: Sendable {
    case clipboardRead
    case voicePreview
    case historyReplay
    case settingsRestart

    public var historySource: HistorySource? {
        self == .clipboardRead ? .clipboard : nil
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
