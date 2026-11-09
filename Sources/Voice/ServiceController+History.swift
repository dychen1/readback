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
        historyPlayback.requestDidEnd(nil)
        stopReading()
    }
}
