import ReadBackCore

@MainActor
extension ServiceController {
    /// Stops whatever plays and reads the entry again with the current voice. The replay does
    /// not add a history entry.
    func replayFromHistory(_ entry: HistoryEntry) {
        historyList.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .starting))
        Task {
            // The clipboard path cancels only its own earlier request. Without this call, an
            // agent or voicepipe reading blocks the replay.
            await coordinator.stop()
            let requestID = startClipboardSpeech(
                entry.text,
                purpose: .historyReplay,
                completionStatus: "Replay finished"
            ) { [historyList] error in
                historyList.replayDidFail(
                    "ReadBack cannot replay this entry. \(error.localizedDescription)"
                )
            }
            historyReplay = (requestID, entry.id)
            syncHistoryPlayback()
        }
    }

    /// Stops the current reading, whatever started it.
    func stopCurrentReading() {
        if clipboardPlaybackState == .starting {
            cancelPendingClipboardSpeech()
        }
        Task { await coordinator.stop() }
    }

    /// Sends the state of the current replay to the History window. Only replays have a known
    /// History entry, so the window shows no playback state for other readings.
    func syncHistoryPlayback() {
        guard let replay = historyReplay, replay.requestID == clipboardRequestID else {
            historyReplay = nil
            historyList.playbackDidChange(nil)
            return
        }
        let phase: HistoryPlayback.Phase? = switch clipboardPlaybackState {
        case .idle: nil
        case .starting: .starting
        case .playing: .playing
        case .paused: .paused
        }
        if phase == nil {
            historyReplay = nil
        }
        historyList.playbackDidChange(phase.map { HistoryPlayback(entryID: replay.entryID, phase: $0) })
    }
}
