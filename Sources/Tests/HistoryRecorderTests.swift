import Foundation
import ReadBackCore

func historyRecorderTests() -> [TestCase] {
    [
        TestCase(name: "history recorder skips blank text") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let recorder = HistoryRecorder(store: HistoryStore(fileURL: file))

            let id = await recorder.record(" \n\t", source: .clipboard)

            let entries = try await recorder.store.entries()
            try expectEqual(id, nil, "blank text id")
            try expectEqual(entries, [], "no entry for blank text")
        },
        TestCase(name: "history recorder saves the text, source and time of a reading") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let recorder = HistoryRecorder(store: HistoryStore(fileURL: file), now: { now })

            let id = await recorder.record("Read this back.", source: .agent(host: "Codex"))

            let entries = try await recorder.store.entries()
            try expectEqual(
                entries,
                [HistoryEntry(id: id ?? -1, createdAt: now, source: .agent(host: "Codex"), text: "Read this back.")],
                "recorded entry"
            )
        },
        TestCase(name: "history recorder returns nil instead of failing when the store is unavailable") {
            let file = try makeUnopenableHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let recorder = HistoryRecorder(store: HistoryStore(fileURL: file))

            let id = await recorder.record("Still spoken.", source: .clipboard)
            var stream = recorder.stream(source: .voicepipe)
            await stream.append("Also spoken.")

            try expectEqual(id, nil, "unavailable store id")
        },
        TestCase(name: "streamed history starts at the first non-blank text and grows until finished") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let recorder = HistoryRecorder(store: HistoryStore(fileURL: file))
            var stream = recorder.stream(source: .voicepipe)

            await stream.append("  ")
            let beforeText = try await recorder.store.entries()
            try expectEqual(beforeText, [], "no entry before real text")
            await stream.append("First sentence.")
            let afterStart = try await recorder.store.entries()
            try expectEqual(
                afterStart.map(\.text),
                ["First sentence."],
                "entry exists as soon as the reading starts"
            )
            await stream.append(" Second sentence.")
            stream.finish()
            await stream.append(" Sent after input.done.")

            let entries = try await recorder.store.entries()
            try expectEqual(entries.map(\.text), ["First sentence. Second sentence."], "streamed text")
            try expectEqual(entries.map(\.source), [.voicepipe], "streamed source")
        },
        TestCase(name: "streamed history stops when its entry is deleted") {
            let file = makeHistoryFileURL()
            defer { removeHistoryDirectory(of: file) }
            let recorder = HistoryRecorder(store: HistoryStore(fileURL: file))
            var stream = recorder.stream(source: .voicepipe)

            await stream.append("One.")
            let id = try await recorder.store.entries()[0].id
            try await recorder.store.delete(id: id)
            await stream.append(" Two.")
            await stream.append(" Three.")

            let entries = try await recorder.store.entries()
            try expectEqual(entries, [], "deleted entry stays deleted")
        },
        TestCase(name: "only clipboard reads from the app are saved to history") {
            try expectEqual(AppSpeechPurpose.clipboardRead.historySource, .clipboard, "clipboard read")
            try expectEqual(AppSpeechPurpose.voicePreview.historySource, nil, "voice preview")
            try expectEqual(AppSpeechPurpose.historyReplay.historySource, nil, "history replay")
            try expectEqual(AppSpeechPurpose.settingsRestart.historySource, nil, "settings restart")
        },
        TestCase(name: "agent host names are cleaned before they are saved") {
            try expectEqual(HistorySource.agent(reportedHost: nil), .agent(host: nil), "missing host")
            try expectEqual(HistorySource.agent(reportedHost: "  \n"), .agent(host: nil), "blank host")
            try expectEqual(
                HistorySource.agent(reportedHost: "  Claude\u{7} Code\n"),
                .agent(host: "Claude Code"),
                "trimmed host without control characters"
            )
            let long = String(repeating: "x", count: 100)
            try expectEqual(
                HistorySource.agent(reportedHost: long),
                .agent(host: String(repeating: "x", count: HistorySource.maximumAgentHostLength)),
                "length-limited host"
            )
        },
    ]
}
