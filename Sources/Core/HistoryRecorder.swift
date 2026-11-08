import Foundation
import os

/// The single entry point speech paths use to add to history.
///
/// Recording never throws: a history failure is logged and the reading carries on.
public struct HistoryRecorder: Sendable {
    public let store: HistoryStore
    private let now: @Sendable () -> Date
    private static let logger = Logger(subsystem: "ai.sanrin.readback", category: "history")

    public init(store: HistoryStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Saves a reading that has just started. Returns the new entry's ID, or `nil` when the
    /// text is blank or could not be saved.
    @discardableResult
    public func record(_ text: String, source: HistorySource) async -> Int64? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try await store.insert(text, source: source, at: now())
        } catch {
            Self.logger.error(
                "Could not save a history entry: \(error.localizedDescription, privacy: .public)"
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
                "Could not extend history entry \(id): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

/// Records one streamed reading. The entry is created with the first non-blank text and
/// grows as text arrives, so an interrupted stream keeps everything sent so far.
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
            // Stop after a failed append (including the user deleting the entry): an entry
            // with a gap in the middle would replay something that was never heard.
            let appended = await recorder.append(text, to: entryID)
            isFinished = !appended
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entryID = await recorder.record(text, source: source)
            isFinished = entryID == nil
        }
    }

    /// Ends the recording; later text is ignored.
    public mutating func finish() {
        isFinished = true
    }
}

/// Why the app itself is speaking. Only clipboard reads become history: previews are not
/// something the user asked to hear, and replays and restarts repeat an existing entry.
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

    /// An agent source from a client-supplied host name, which is untrusted and optional.
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
