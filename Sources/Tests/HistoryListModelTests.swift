import Foundation
import ReadBackCore

@MainActor
private final class PlaybackLog {
    var replayed: [HistoryEntry] = []
    var stops = 0
}

@MainActor
private func makeModel(file: URL) -> (HistoryListModel, HistoryStore, PlaybackLog) {
    let store = HistoryStore(fileURL: file)
    let log = PlaybackLog()
    let model = HistoryListModel(
        store: store,
        replay: { log.replayed.append($0) },
        stop: { log.stops += 1 }
    )
    return (model, store, log)
}

/// Saves entries oldest first, so `texts.last` becomes the newest entry.
private func insert(_ texts: [String], into store: HistoryStore) async throws {
    for text in texts {
        try await store.insert(text, source: .clipboard, at: Date())
    }
}

func historyListModelTests() -> [TestCase] {
    [
        TestCase(name: "history list loads entries newest first and selects the newest") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Older", "Newer"], into: store)

            try expectEqual(model.state, .loading, "state before loading")
            await model.refresh()

            try expectEqual(model.entries.map(\.text), ["Newer", "Older"], "listed entries")
            try expectEqual(model.selectedEntry?.text, "Newer", "first load selects the newest entry")
        },
        TestCase(name: "history list keeps the selection when a new entry arrives") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["First", "Second"], into: store)
            await model.refresh()
            model.selectedEntryID = model.entries[1].id

            try await insert(["Third"], into: store)
            await model.refresh()

            try expectEqual(model.entries.map(\.text), ["Third", "Second", "First"], "entries")
            try expectEqual(model.selectedEntry?.text, "First", "selection stays on the same entry")
        },
        TestCase(name: "history list explains why history is unavailable") { @MainActor in
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, _, _) = makeModel(file: file)

            await model.refresh()

            guard case .unavailable(let message) = model.state else {
                throw TestFailure(description: "expected unavailable, got \(model.state)")
            }
            try expect(message.hasPrefix("ReadBack cannot open"), "message: \(message)")
            try expect(message.contains(file.path), "message names the file: \(message)")
            try expectEqual(model.entries, [], "no entries while unavailable")
            try expectEqual(model.selectedEntryID, nil, "no selection while unavailable")
        },
        TestCase(name: "deleting the selected entry selects the next older entry") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Oldest", "Middle", "Newest"], into: store)
            await model.refresh()
            model.selectedEntryID = model.entries[1].id

            await model.deleteSelected()
            try expectEqual(model.entries.map(\.text), ["Newest", "Oldest"], "after deleting Middle")
            try expectEqual(model.selectedEntry?.text, "Oldest", "next older entry")

            await model.deleteSelected()
            try expectEqual(model.selectedEntry?.text, "Newest", "newer entry when no older one exists")

            await model.deleteSelected()
            try expectEqual(model.selectedEntryID, nil, "nothing left to select")
            try expectEqual(model.actionError, nil, "no errors")
        },
        TestCase(name: "deleting an unselected entry keeps the selection") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Keep", "Remove"], into: store)
            await model.refresh()
            model.selectedEntryID = model.entries[1].id

            await model.delete(model.entries[0])

            try expectEqual(model.selectedEntry?.text, "Keep", "selection")
        },
        TestCase(name: "deleting the playing entry stops playback first") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, log) = makeModel(file: file)
            try await insert(["Playing"], into: store)
            await model.refresh()
            let entry = model.entries[0]
            model.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .playing))

            await model.delete(entry)

            try expectEqual(log.stops, 1, "stop count")
            try expectEqual(model.entries, [], "entry deleted")
        },
        TestCase(name: "history list clears after confirmation and stops playback") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, log) = makeModel(file: file)
            try await insert(["One", "Two"], into: store)
            await model.refresh()
            model.playbackDidChange(HistoryPlayback(entryID: model.entries[0].id, phase: .playing))

            try expectEqual(model.clearConfirmationTitle, "Clear all 2 read-backs?", "plural title")
            model.requestClear()
            try expect(model.isConfirmingClear, "clear asks for confirmation")
            model.cancelClear()
            try expect(!model.isConfirmingClear, "confirmation can be canceled")
            try expectEqual(model.entries.count, 2, "canceling keeps entries")

            model.requestClear()
            await model.clear()
            try expect(!model.isConfirmingClear, "confirmation closes after clearing")
            try expectEqual(model.state, .loaded([]), "after clear")
            try expectEqual(model.selectedEntryID, nil, "nothing selected after clear")
            try expectEqual(log.stops, 1, "clear stops playback")
            let stored = try await store.entries()
            try expectEqual(stored, [], "store after clear")

            model.requestClear()
            try expect(!model.isConfirmingClear, "nothing to confirm for an empty list")
        },
        TestCase(name: "the clear title names one read-back") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Only"], into: store)
            await model.refresh()

            try expectEqual(model.clearConfirmationTitle, "Clear 1 read-back?", "singular title")
        },
        TestCase(name: "history list reports a failed delete") { @MainActor in
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, _, _) = makeModel(file: file)

            await model.delete(HistoryEntry(id: 1, createdAt: Date(), source: .clipboard, text: "Gone"))

            let error = model.actionError ?? ""
            try expect(error.hasPrefix("ReadBack did not delete the entry. "), "action error: \(error)")
        },
        TestCase(name: "history list replays an entry without adding a new one") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, log) = makeModel(file: file)
            try await store.insert("Say it again.", source: .agent(host: "Cursor"), at: Date())
            await model.refresh()

            model.play(model.entries[0])

            try expectEqual(log.replayed.map(\.text), ["Say it again."], "replayed text")
            let stored = try await store.entries()
            try expectEqual(stored.count, 1, "replay adds no entry")
        },
        TestCase(name: "space stops the selected entry while it starts, plays or pauses") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, log) = makeModel(file: file)
            try await insert(["Other", "Selected"], into: store)
            await model.refresh()
            let selected = model.entries[0]
            let other = model.entries[1]

            model.togglePlaySelected()
            try expectEqual(log.replayed.map(\.id), [selected.id], "space plays when idle")

            for phase in [HistoryPlayback.Phase.starting, .playing, .paused] {
                model.playbackDidChange(HistoryPlayback(entryID: selected.id, phase: phase))
                try expect(model.isSelectionPlaying, "Play button reads Stop while \(phase)")
                model.togglePlaySelected()
            }
            try expectEqual(log.stops, 3, "space stops in each phase")
            try expectEqual(log.replayed.count, 1, "space does not replay while playing")

            model.playbackDidChange(HistoryPlayback(entryID: other.id, phase: .playing))
            try expect(!model.isSelectionPlaying, "another entry plays")
            model.togglePlaySelected()
            try expectEqual(log.replayed.map(\.id), [selected.id, selected.id], "space plays the selection")
        },
        TestCase(name: "return replays the selected entry from the start") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, log) = makeModel(file: file)
            try await insert(["Again"], into: store)
            await model.refresh()
            model.playbackDidChange(HistoryPlayback(entryID: model.entries[0].id, phase: .playing))

            model.playSelected()

            try expectEqual(log.replayed.map(\.text), ["Again"], "return restarts the entry")
            try expectEqual(log.stops, 0, "return does not stop")
        },
        TestCase(name: "a failed replay shows its message until the next replay") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Entry"], into: store)
            await model.refresh()

            model.replayDidFail("ReadBack cannot replay this entry. The model is loading.")
            model.playbackDidChange(nil)
            try expectEqual(
                model.playbackError,
                "ReadBack cannot replay this entry. The model is loading.",
                "error stays after playback ends"
            )

            model.playSelected()
            try expectEqual(model.playbackError, nil, "next replay clears the error")
        },
        TestCase(name: "rows show a playback mark only while audio plays or pauses") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Other", "Entry"], into: store)
            await model.refresh()
            let entry = model.entries[0]
            let other = model.entries[1]

            try expectEqual(model.rowIndicator(for: entry), .none, "idle")
            model.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .starting))
            try expectEqual(model.rowIndicator(for: entry), .none, "starting")
            model.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .playing))
            try expectEqual(model.rowIndicator(for: entry), .playing, "playing")
            try expectEqual(model.rowIndicator(for: other), .none, "other row")
            model.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .paused))
            try expectEqual(model.rowIndicator(for: entry), .paused, "paused")
        },
        TestCase(name: "the reader highlights only the entry that plays") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await insert(["Other", "Cafe\u{301} au lait. Then more."], into: store)
            await model.refresh()
            let entry = model.entries[0]
            let other = model.entries[1]

            model.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .starting))
            try expectEqual(model.spokenRange(in: entry), nil, "no range before the first chunk")
            try expectEqual(model.progress(in: entry), nil, "no progress before the first chunk")
            model.playbackDidChange(HistoryPlayback(entryID: entry.id, phase: .playing, spokenRange: 15..<25))
            try expectEqual(model.spokenRange(in: entry), 14..<24, "scalar range becomes a character range")
            try expectEqual(model.progress(in: entry), 15.0 / 25.0, "progress counts scalars before the chunk")
            try expectEqual(model.spokenRange(in: other), nil, "another entry has no highlight")
            try expectEqual(model.progress(in: other), nil, "another entry has no progress")
        },
        TestCase(name: "escape stops whatever plays") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, _, log) = makeModel(file: file)

            model.stopPlayback()

            try expectEqual(log.stops, 1, "stop count")
        },
        TestCase(name: "history list follows new readings while observed") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            let observer = Task { await model.observeChanges() }
            defer { observer.cancel() }

            await HistoryRecorder(store: store).record("Just heard.", source: .clipboard)

            for _ in 0..<200 where model.entries.isEmpty {
                try await wait(for: .milliseconds(10))
            }
            try expectEqual(model.entries.map(\.text), ["Just heard."], "observed entry")
            try expectEqual(model.selectedEntry?.text, "Just heard.", "first arrival is selected")
        },
    ]
}
