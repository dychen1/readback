import Foundation
import ReadBackCore

private let newYork = TimeZone(identifier: "America/New_York")!

private let labels: HistoryDateLabels = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    return HistoryDateLabels(calendar: calendar, locale: Locale(identifier: "en_US"))
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    components.timeZone = newYork
    return Calendar(identifier: .gregorian).date(from: components)!
}

/// Sunday, November 8, 2026 at 4:00 PM in New York.
private let now = date(2026, 11, 8, 16, 0)

/// Recent macOS versions put a narrow no-break space before "AM" and "PM".
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
}

private func entry(_ id: Int64, _ createdAt: Date, _ text: String = "Text.", source: HistorySource = .clipboard)
    -> HistoryEntry
{
    HistoryEntry(id: id, createdAt: createdAt, source: source, text: text)
}

func historyPresentationTests() -> [TestCase] {
    [
        TestCase(name: "history day titles use today, yesterday, weekdays, then dates") {
            let cases: [(Date, String)] = [
                (date(2026, 11, 8, 23, 59), "Today"),
                (date(2026, 11, 8, 0, 0), "Today"),
                (date(2026, 11, 9, 9, 0), "Today"),
                (date(2026, 11, 7, 23, 59), "Yesterday"),
                (date(2026, 11, 6, 12, 0), "Friday"),
                (date(2026, 11, 2, 12, 0), "Monday"),
                (date(2026, 11, 1, 12, 0), "November 1"),
                (date(2025, 10, 28, 12, 0), "October 28, 2025"),
            ]
            for (day, expected) in cases {
                try expectEqual(labels.dayTitle(for: day, now: now), expected, "title for \(day)")
            }
        },
        TestCase(name: "history time, full date and subtitle labels") {
            let heard = date(2026, 11, 8, 11, 12)
            try expectEqual(plain(labels.time(heard)), "11:12 AM", "time")
            try expectEqual(plain(labels.fullDate(heard)), "Sunday, November 8 at 11:12 AM", "full date")
            try expectEqual(
                plain(labels.subtitle(for: entry(1, heard))),
                "From Clipboard, Sunday, November 8 at 11:12 AM",
                "subtitle"
            )
            try expectEqual(
                plain(labels.subtitle(for: entry(2, heard, source: .agent(host: "Claude Code")))),
                "From Claude Code, Sunday, November 8 at 11:12 AM",
                "agent subtitle"
            )
        },
        TestCase(name: "history groups entries by day in list order") {
            let entries = [
                entry(4, date(2026, 11, 8, 15, 58)),
                entry(3, date(2026, 11, 8, 11, 12)),
                entry(2, date(2026, 11, 7, 18, 40)),
                entry(1, date(2026, 10, 28, 9, 5)),
            ]

            let groups = labels.groups(entries, now: now)

            try expectEqual(groups.map(\.title), ["Today", "Yesterday", "October 28"], "group titles")
            try expectEqual(groups.map { $0.entries.map(\.id) }, [[4, 3], [2], [1]], "group entries")
            try expectEqual(labels.groups([], now: now), [], "no groups without entries")

            // The clock moved back between entries 2 and 1, so their day appears twice in ID order.
            let afterClockChange = labels.groups(
                [entry(3, date(2026, 11, 8, 9, 0)), entry(2, date(2026, 11, 7, 9, 0)), entry(1, date(2026, 11, 8, 8, 0))],
                now: now
            )
            try expectEqual(afterClockChange.map(\.title), ["Today", "Yesterday"], "one group for each day")
            try expectEqual(afterClockChange.map { $0.entries.map(\.id) }, [[3, 1], [2]], "merged group entries")
        },
        TestCase(name: "history row labels for VoiceOver name the state") {
            let heard = entry(
                1,
                date(2026, 11, 8, 11, 12),
                "Sound reaches the ear as one wave. The brain groups fragments."
            )
            try expectEqual(
                plain(labels.accessibilityLabel(for: heard, indicator: .playing)),
                "Clipboard, 11:12 AM, playing: Sound reaches the ear as one wave.",
                "playing label"
            )
            try expectEqual(
                plain(labels.accessibilityLabel(for: heard, indicator: .paused)),
                "Clipboard, 11:12 AM, paused: Sound reaches the ear as one wave.",
                "paused label"
            )
            try expectEqual(
                plain(labels.accessibilityLabel(for: heard, indicator: .none)),
                "Clipboard, 11:12 AM: Sound reaches the ear as one wave.",
                "idle label"
            )
        },
        TestCase(name: "history previews use the first sentence of the first line") {
            let cases: [(String, String)] = [
                ("\n  The change is working, and tests pass. Next step.\nSecond line", "The change is working, and tests pass."),
                ("Build succeeded in 42 seconds", "Build succeeded in 42 seconds"),
                ("Is it done? Yes.", "Is it done?"),
                ("   ", ""),
            ]
            for (text, expected) in cases {
                try expectEqual(entry(1, now, text).firstSentence, expected, "preview of \(text.debugDescription)")
            }
            try expectEqual(entry(1, now, "\n   \n  Title line  \nSecond line").firstLine, "Title line", "first line")
        },
        TestCase(name: "history sources have a name and a symbol") {
            try expectEqual(HistorySource.agent(host: "Cursor").displayName, "Cursor", "named agent")
            try expectEqual(HistorySource.agent(host: nil).displayName, "Agent", "unnamed agent")
            try expectEqual(HistorySource.clipboard.displayName, "Clipboard", "clipboard")
            for builtIn in ["Clipboard", "clipboard", "voicepipe", "Agent"] {
                try expectEqual(
                    HistorySource.agent(host: builtIn).displayName,
                    "Agent · \(builtIn)",
                    "an agent named \(builtIn) does not pass as a built-in source"
                )
            }
            try expectEqual(HistorySource.voicepipe.displayName, "voicepipe", "voicepipe")
            try expectEqual(HistorySource.agent(host: nil).symbolName, "text.bubble", "agent symbol")
            try expectEqual(HistorySource.clipboard.symbolName, "clipboard", "clipboard symbol")
            try expectEqual(HistorySource.voicepipe.symbolName, "terminal", "voicepipe symbol")
        },
        TestCase(name: "history paragraphs split at blank lines and keep their offsets") {
            let text = "First paragraph.\nSame paragraph.\n\n  \n Second paragraph.  \n\n\n👋🏽 Third."
            let paragraphs = entry(1, now, text).paragraphs
            let characters = Array(text)

            try expectEqual(
                paragraphs.map(\.text),
                ["First paragraph.\nSame paragraph.", "Second paragraph.", "👋🏽 Third."],
                "paragraph texts"
            )
            try expectEqual(paragraphs.map(\.id), [0, 1, 2], "paragraph ids")
            for paragraph in paragraphs {
                try expectEqual(
                    String(characters[paragraph.range]),
                    paragraph.text,
                    "offsets of paragraph \(paragraph.id)"
                )
            }
            try expectEqual(entry(1, now, " \n\n ").paragraphs, [], "blank text")
        },
        TestCase(name: "history playback follows any reading that has a history entry") {
            try expectEqual(HistoryPlayback(nil), nil, "nothing plays")
            try expectEqual(
                HistoryPlayback(SpeechPlaybackState(sessionID: "preview", phase: .playing, chunkRange: 0..<4)),
                nil,
                "a reading without an entry"
            )
            try expectEqual(
                HistoryPlayback(SpeechPlaybackState(sessionID: "agent", historyEntryID: 3)),
                HistoryPlayback(entryID: 3, phase: .starting),
                "starting reading has no spoken range"
            )
            try expectEqual(
                HistoryPlayback(
                    SpeechPlaybackState(sessionID: "agent", historyEntryID: 3, phase: .playing, chunkRange: 10..<20)
                ),
                HistoryPlayback(entryID: 3, phase: .playing, spokenRange: 10..<20),
                "playing chunk becomes the spoken range"
            )
            try expectEqual(
                HistoryPlayback(
                    SpeechPlaybackState(sessionID: "agent", historyEntryID: 3, phase: .paused, chunkRange: 10..<20)
                ),
                HistoryPlayback(entryID: 3, phase: .paused, spokenRange: 10..<20),
                "pause keeps the spoken range"
            )
        },
        TestCase(name: "history converts scalar offsets to character offsets") {
            let text = entry(1, Date(), "Cafe\u{301} 👩‍👩‍👧 ok")
            try expectEqual(text.characterRange(forScalarRange: 0..<5), 0..<4, "combining accent")
            try expectEqual(text.characterRange(forScalarRange: 6..<11), 5..<6, "emoji family")
            try expectEqual(text.characterRange(forScalarRange: 12..<14), 7..<9, "word after both")
            try expectEqual(text.characterRange(forScalarRange: 4..<8), 3..<6, "offsets inside characters widen")
            try expectEqual(text.characterRange(forScalarRange: 12..<99), 7..<9, "offsets past the end")
        },
        TestCase(name: "history progress counts the text before the spoken range") {
            let none = HistoryPlayback(entryID: 1, phase: .playing)
            try expectEqual(none.progress(textLength: 100), nil, "no progress without a range")

            let cases: [(Range<Int>, Int, Double?)] = [
                (0..<25, 100, 0),
                (25..<50, 100, 0.25),
                (90..<120, 100, 0.9),
                (150..<160, 100, 1),
                (0..<10, 0, nil),
            ]
            for (range, length, expected) in cases {
                let playback = HistoryPlayback(entryID: 1, phase: .playing, spokenRange: range)
                try expectEqual(playback.progress(textLength: length), expected, "progress for \(range) of \(length)")
            }
        },
        TestCase(name: "history paragraph runs split around the spoken range") {
            let text = "One two.\n\nThree four five."
            let second = entry(1, now, text).paragraphs[1]
            try expectEqual(second.range, 10..<26, "second paragraph offsets")

            try expectEqual(
                second.runs(spokenRange: nil),
                HistoryParagraphRuns(spoken: "", current: "", upcoming: "Three four five."),
                "no highlight"
            )
            try expectEqual(
                second.runs(spokenRange: 16..<20),
                HistoryParagraphRuns(spoken: "Three ", current: "four", upcoming: " five."),
                "range inside the paragraph"
            )
            try expectEqual(
                second.runs(spokenRange: 0..<8),
                HistoryParagraphRuns(spoken: "", current: "", upcoming: "Three four five."),
                "range in an earlier paragraph"
            )
            try expectEqual(
                entry(1, now, text).paragraphs[0].runs(spokenRange: 16..<20),
                HistoryParagraphRuns(spoken: "One two.", current: "", upcoming: ""),
                "paragraph before the range"
            )
            try expectEqual(
                second.runs(spokenRange: 20..<500),
                HistoryParagraphRuns(spoken: "Three four", current: " five.", upcoming: ""),
                "range past the end is clamped"
            )
        },
    ]
}
