import Foundation

/// Tells the History window which entry plays while the app reads the clipboard, replays an
/// entry or restarts a reading after a settings change. Such a request has no speech session
/// until its stream starts, so the tracker shows a replayed entry as starting until then.
@MainActor
public final class HistoryPlaybackTracker {
    private let list: HistoryListModel
    private let coordinator: SpeechCoordinator
    private let recorder: HistoryRecorder
    private let activeRequestID: @MainActor () -> UUID?
    /// A replay or restart of an entry, from its start until its reading has a session.
    private var pending: (requestID: UUID, entryID: HistoryEntry.ID)?
    private var speechPlayback: SpeechPlaybackState?

    /// - Parameter activeRequestID: The app request that is current now, if any.
    public init(
        list: HistoryListModel,
        coordinator: SpeechCoordinator,
        recorder: HistoryRecorder,
        activeRequestID: @escaping @MainActor () -> UUID?
    ) {
        self.list = list
        self.coordinator = coordinator
        self.recorder = recorder
        self.activeRequestID = activeRequestID
    }

    /// Call when the app starts `requestID`. A replay or restart shows its entry at once.
    public func requestDidStart(_ requestID: UUID, purpose: AppSpeechPurpose) {
        switch purpose {
        case .historyReplay(let entryID), .settingsRestart(let entryID?):
            pending = (requestID, entryID)
        case .clipboardRead, .voicePreview, .settingsRestart(nil):
            pending = nil
        }
        refresh()
    }

    /// Call when `requestID` ends. `nil` ends whatever request is pending.
    public func requestDidEnd(_ requestID: UUID?) {
        guard let pending, requestID == nil || pending.requestID == requestID else { return }
        self.pending = nil
        refresh()
    }

    /// Call with each state from `SpeechCoordinator.playbackUpdates()`.
    public func speechPlaybackDidChange(_ state: SpeechPlaybackState?) {
        speechPlayback = state
        refresh()
    }

    /// Connects the reading of `requestID` to its history entry once the reading has a
    /// session. A clipboard read becomes a new entry here. Returns the entry, if any.
    @discardableResult
    public func linkEntry(
        requestID: UUID,
        sessionID: String?,
        purpose: AppSpeechPurpose,
        text: String
    ) async -> HistoryEntry.ID? {
        guard let entryID = await recorder.entryID(for: purpose, text: text) else { return nil }
        if let sessionID {
            await coordinator.linkHistoryEntry(entryID, toSession: sessionID)
            // The update stream can deliver the linked state after this returns. Without this
            // read, the window would show the old state without the entry for one update.
            speechPlayback = await coordinator.currentPlaybackState
        }
        if pending?.requestID == requestID {
            pending = nil
        }
        refresh()
        return entryID
    }

    private func refresh() {
        if let pending {
            if activeRequestID() == pending.requestID {
                list.playbackDidChange(HistoryPlayback(entryID: pending.entryID, phase: .starting))
                return
            }
            self.pending = nil
        }
        list.playbackDidChange(HistoryPlayback(speechPlayback))
    }
}
