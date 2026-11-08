import Foundation
import ReadBackCore

@MainActor
private final class ReplayLog {
    var entries: [HistoryEntry] = []
}

@MainActor
private func makeModel(file: URL) -> (HistoryListModel, HistoryStore, ReplayLog) {
    let store = HistoryStore(fileURL: file)
    let log = ReplayLog()
    let model = HistoryListModel(store: store) { log.entries.append($0) }
    return (model, store, log)
}

func historyListModelTests() -> [TestCase] {
    [
        TestCase(name: "history list loads entries newest first") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await store.insert("Older", source: .clipboard, at: Date())
            try await store.insert("Newer", source: .voicepipe, at: Date())

            try expectEqual(model.state, .loading, "state before loading")
            await model.refresh()

            try expectEqual(model.entries.map(\.text), ["Newer", "Older"], "listed entries")
        },
        TestCase(name: "history list explains why history is unavailable") { @MainActor in
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, _, _) = makeModel(file: file)

            await model.refresh()

            guard case .unavailable(let message) = model.state else {
                throw TestFailure(description: "expected unavailable, got \(model.state)")
            }
            try expect(message.hasPrefix("History is unavailable."), "message: \(message)")
            try expect(message.contains(file.path), "message names the file: \(message)")
            try expectEqual(model.entries, [], "no entries while unavailable")
        },
        TestCase(name: "history list deletes an entry and clears after confirmation") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, _) = makeModel(file: file)
            try await store.insert("Keep", source: .clipboard, at: Date())
            try await store.insert("Remove", source: .clipboard, at: Date())
            await model.refresh()

            await model.delete(model.entries[0])
            try expectEqual(model.entries.map(\.text), ["Keep"], "after delete")

            model.requestClear()
            try expect(model.isConfirmingClear, "clear asks for confirmation")
            model.cancelClear()
            try expect(!model.isConfirmingClear, "confirmation can be cancelled")
            try expectEqual(model.entries.count, 1, "cancelling keeps entries")

            model.requestClear()
            await model.clear()
            try expect(!model.isConfirmingClear, "confirmation closes after clearing")
            try expectEqual(model.state, .loaded([]), "after clear")
            let stored = try await store.entries()
            try expectEqual(stored, [], "store after clear")

            model.requestClear()
            try expect(!model.isConfirmingClear, "nothing to confirm for an empty list")
            try expectEqual(model.actionError, nil, "no errors")
        },
        TestCase(name: "history list reports a failed delete") { @MainActor in
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, _, _) = makeModel(file: file)

            await model.delete(HistoryEntry(id: 1, createdAt: Date(), source: .clipboard, text: "Gone"))

            let error = model.actionError ?? ""
            try expect(error.hasPrefix("Could not delete the entry:"), "action error: \(error)")
        },
        TestCase(name: "history list replays an entry without adding a new one") { @MainActor in
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let (model, store, log) = makeModel(file: file)
            try await store.insert("Say it again.", source: .agent(host: "Cursor"), at: Date())
            await model.refresh()

            model.play(model.entries[0])

            try expectEqual(log.entries.map(\.text), ["Say it again."], "replayed text")
            let stored = try await store.entries()
            try expectEqual(stored.count, 1, "replay adds no entry")
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
        },
        TestCase(name: "history rows show the first line and a source name") {
            let entry = HistoryEntry(
                id: 1,
                createdAt: Date(),
                source: .clipboard,
                text: "\n   \n  Title line  \nSecond line"
            )
            try expectEqual(entry.firstLine, "Title line", "first non-blank line")
            try expectEqual(HistorySource.agent(host: "Cursor").displayName, "Agent · Cursor", "named agent")
            try expectEqual(HistorySource.agent(host: nil).displayName, "Agent", "unnamed agent")
            try expectEqual(HistorySource.clipboard.displayName, "Clipboard", "clipboard")
            try expectEqual(HistorySource.voicepipe.displayName, "voicepipe", "voicepipe")
        },
    ]
}
