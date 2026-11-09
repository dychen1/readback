import ReadBackCore

@MainActor
extension ServiceController {
    /// Reads the entry again with the current voice. The replay replaces the current reading,
    /// whatever started it, and does not add a history entry.
    func replayFromHistory(_ entry: HistoryEntry) {
        startClipboardSpeech(
            entry.text,
            purpose: .historyReplay(entry.id),
            completionStatus: "Replay finished"
        ) { [historyList] error in
            historyList.replayDidFail(
                "ReadBack cannot replay this entry. \(error.localizedDescription)"
            )
        }
    }

    /// Stops the current reading, whatever started it. A clipboard request that has no
    /// session yet is canceled too.
    func stopCurrentReading() {
        if clipboardPlaybackState == .starting {
            cancelPendingClipboardSpeech()
        }
        pendingHistoryPlayback = nil
        refreshHistoryPlayback()
        stopReading()
    }

    /// Sends the playback state of the current reading to the History window. Any reading
    /// that has a history entry shows there: agent read-backs, clipboard reads, voicepipe
    /// streams and replays.
    func refreshHistoryPlayback() {
        if let pending = pendingHistoryPlayback {
            if clipboardRequestID == pending.requestID {
                historyList.playbackDidChange(HistoryPlayback(entryID: pending.entryID, phase: .starting))
                return
            }
            pendingHistoryPlayback = nil
        }
        historyList.playbackDidChange(HistoryPlayback(speechPlayback))
    }
}
