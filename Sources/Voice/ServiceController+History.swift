import ReadBackCore

@MainActor
extension ServiceController {
    /// Stops whatever is playing and reads the entry again with the current voice. The
    /// replay does not add a history entry.
    func replayFromHistory(_ entry: HistoryEntry) {
        Task {
            // The clipboard path cancels only its own earlier request. Without this call, an
            // agent or voicepipe reading blocks the replay.
            await coordinator.stop()
            startClipboardSpeech(
                entry.text,
                purpose: .historyReplay,
                completionStatus: "Replay finished"
            )
        }
    }
}
