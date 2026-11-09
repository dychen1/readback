import Foundation
import ReadBackCore

@MainActor
private final class TrackerFixture {
    let store: HistoryStore
    let coordinator = SpeechCoordinator(synthesizer: RecordingSynthesizer(), player: RecordingAudioPlayer())
    let list: HistoryListModel
    var activeRequestID: UUID?
    private(set) lazy var tracker = HistoryPlaybackTracker(
        list: list,
        coordinator: coordinator,
        recorder: HistoryRecorder(store: store),
        activeRequestID: { [unowned self] in self.activeRequestID }
    )

    init(file: URL) {
        store = HistoryStore(fileURL: file)
        list = HistoryListModel(store: store, replay: { _ in }, stop: {})
    }
}

func historyPlaybackTrackerTests() -> [TestCase] {
    [
        TestCase(name: "history tracker shows a replay as starting, then keeps the entry when it links") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = TrackerFixture(file: file)
            let entryID = try await fixture.store.insert("Replay me.", source: .clipboard, at: Date())
            let requestID = UUID()
            fixture.activeRequestID = requestID

            fixture.tracker.requestDidStart(requestID, purpose: .historyReplay(entryID))
            try expectEqual(
                fixture.list.playback,
                HistoryPlayback(entryID: entryID, phase: .starting),
                "a replay shows its entry before it has a session"
            )

            try await fixture.coordinator.replaceSession(id: "replay") { _ in }
            // The update stream delivers the new session before the link names its entry.
            fixture.tracker.speechPlaybackDidChange(SpeechPlaybackState(sessionID: "replay"))
            try expectEqual(fixture.list.playback?.entryID, entryID, "the pending replay still shows")

            let linked = await fixture.tracker.linkEntry(
                requestID: requestID,
                sessionID: "replay",
                purpose: .historyReplay(entryID),
                text: "Replay me."
            )
            try expectEqual(linked, entryID, "a replay links the entry it repeats")
            try expectEqual(
                fixture.list.playback,
                HistoryPlayback(entryID: entryID, phase: .starting),
                "the entry stays after the link, before the update stream catches up"
            )

            fixture.tracker.requestDidEnd(requestID)
            fixture.tracker.speechPlaybackDidChange(nil)
            try expectEqual(fixture.list.playback, nil, "nothing shows after the reading ends")
        },
        TestCase(name: "history tracker links a clipboard read to its new entry") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = TrackerFixture(file: file)
            let requestID = UUID()
            fixture.activeRequestID = requestID

            fixture.tracker.requestDidStart(requestID, purpose: .clipboardRead)
            try expectEqual(fixture.list.playback, nil, "a clipboard read has no entry before it starts")
            try await fixture.coordinator.replaceSession(id: "clipboard") { _ in }
            let linked = await fixture.tracker.linkEntry(
                requestID: requestID,
                sessionID: "clipboard",
                purpose: .clipboardRead,
                text: "Copied text."
            )

            let entries = try await fixture.store.entries()
            try expectEqual(linked, entries.first?.id, "the clipboard read becomes a new entry")
            try expectEqual(fixture.list.playback?.entryID, linked, "the new entry shows as playing")
            let sessionEntry = await fixture.coordinator.currentPlaybackState?.historyEntryID
            try expectEqual(sessionEntry, linked, "the session names the entry")
        },
        TestCase(name: "history tracker drops a pending replay that is no longer the current request") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let fixture = TrackerFixture(file: file)
            let replay = UUID()
            fixture.activeRequestID = replay
            fixture.tracker.requestDidStart(replay, purpose: .historyReplay(3))

            fixture.tracker.requestDidEnd(UUID())
            try expectEqual(fixture.list.playback?.entryID, 3, "another request's end keeps the replay")

            fixture.activeRequestID = UUID()
            fixture.tracker.speechPlaybackDidChange(nil)
            try expectEqual(fixture.list.playback, nil, "a replaced request no longer shows")

            fixture.activeRequestID = replay
            fixture.tracker.speechPlaybackDidChange(nil)
            try expectEqual(fixture.list.playback, nil, "a dropped replay does not come back")
        },
    ]
}
