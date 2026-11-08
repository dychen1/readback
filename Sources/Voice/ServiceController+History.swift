import ReadBackCore

@MainActor
extension ServiceController {
    /// Stops whatever is playing and reads the entry again with the current voice. The
    /// replay does not add a history entry.
    func replayFromHistory(_ entry: HistoryEntry) {
        Task {
            // The clipboard path only cancels its own earlier request, so an agent or
            // voicepipe reading would otherwise block the replay's session.
            await coordinator.stop()
            startClipboardSpeech(
                entry.text,
                purpose: .historyReplay,
                completionStatus: "Replay finished"
            )
        }
    }
}
