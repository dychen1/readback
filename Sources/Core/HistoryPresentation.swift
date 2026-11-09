import Foundation

/// The History entry that plays now, as the History window shows it.
public struct HistoryPlayback: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case starting
        case playing
        case paused
    }

    public let entryID: HistoryEntry.ID
    public let phase: Phase
    /// The part of the entry text that plays now, as character offsets into the entry text.
    /// It stays `nil` until playback reports its progress. The reader shows no highlight for `nil`.
    public let spokenRange: Range<Int>?

    public init(entryID: HistoryEntry.ID, phase: Phase, spokenRange: Range<Int>? = nil) {
        self.entryID = entryID
        self.phase = phase
        self.spokenRange = spokenRange
    }

    /// The fraction of the text that played before the current part, from 0 to 1. The value
    /// moves one part at a time. It is `nil` while `spokenRange` is `nil`.
    public func progress(textLength: Int) -> Double? {
        guard let spokenRange, textLength > 0 else { return nil }
        return Double(min(max(spokenRange.lowerBound, 0), textLength)) / Double(textLength)
    }
}

/// The playback mark at the end of a sidebar row.
public enum HistoryRowIndicator: Equatable, Sendable {
    case none
    case playing
    case paused

    /// The row shows no mark while the reading starts, because no audio plays yet.
    public init(playback: HistoryPlayback?, entryID: HistoryEntry.ID) {
        guard let playback, playback.entryID == entryID else {
            self = .none
            return
        }
        switch playback.phase {
        case .starting: self = .none
        case .playing: self = .playing
        case .paused: self = .paused
        }
    }
}

public struct HistoryDayGroup: Equatable, Identifiable, Sendable {
    /// The start of the day.
    public let id: Date
    public let title: String
    public let entries: [HistoryEntry]
}

/// Makes the date and time text of the History window.
public struct HistoryDateLabels: Sendable {
    public let calendar: Calendar
    public let locale: Locale

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    /// Puts entries into one group for each day. The groups keep the order of the entries.
    public func groups(_ entries: [HistoryEntry], now: Date) -> [HistoryDayGroup] {
        var groups: [HistoryDayGroup] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let last = groups.last, last.id == day {
                groups[groups.count - 1] = HistoryDayGroup(
                    id: day,
                    title: last.title,
                    entries: last.entries + [entry]
                )
            } else {
                groups.append(
                    HistoryDayGroup(id: day, title: dayTitle(for: entry.createdAt, now: now), entries: [entry])
                )
            }
        }
        return groups
    }

    /// "Today", "Yesterday", a weekday name for the last 7 days, then a date.
    public func dayTitle(for date: Date, now: Date) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ...0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2..<7:
            return date.formatted(style.weekday(.wide))
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let dayStyle = style.month(.wide).day()
            return date.formatted(sameYear ? dayStyle : dayStyle.year())
        }
    }

    /// The hour and minute, for example "4:21 PM".
    public func time(_ date: Date) -> String {
        date.formatted(style.hour().minute())
    }

    /// For example "Sunday, November 8 at 11:12 AM".
    public func fullDate(_ date: Date) -> String {
        "\(date.formatted(style.weekday(.wide).month(.wide).day())) at \(time(date))"
    }

    /// The subtitle of the reader, for example "From Clipboard, Sunday, November 8 at 11:12 AM".
    public func subtitle(for entry: HistoryEntry) -> String {
        "From \(entry.source.displayName), \(fullDate(entry.createdAt))"
    }

    /// The VoiceOver label of a sidebar row, for example
    /// "Clipboard, 11:12 AM, playing: Sound reaches the ear as one wave."
    public func accessibilityLabel(for entry: HistoryEntry, indicator: HistoryRowIndicator) -> String {
        let state = switch indicator {
        case .none: ""
        case .playing: ", playing"
        case .paused: ", paused"
        }
        return "\(entry.source.displayName), \(time(entry.createdAt))\(state): \(entry.firstSentence)"
    }

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}

/// One paragraph of an entry, with its position in the entry text.
public struct HistoryParagraph: Equatable, Identifiable, Sendable {
    /// The position of the paragraph in the entry, starting at 0.
    public let id: Int
    public let text: String
    /// Character offsets into the entry text.
    public let range: Range<Int>

    /// Divides the paragraph into the text before, inside and after `spokenRange`. This function
    /// clamps offsets outside the paragraph, so a range that is not valid cannot crash the reader.
    public func runs(spokenRange: Range<Int>?) -> HistoryParagraphRuns {
        guard let spokenRange else {
            return HistoryParagraphRuns(spoken: "", current: "", upcoming: text)
        }
        let characters = Array(text)
        let start = min(max(spokenRange.lowerBound - range.lowerBound, 0), characters.count)
        let end = min(max(spokenRange.upperBound - range.lowerBound, start), characters.count)
        return HistoryParagraphRuns(
            spoken: String(characters[..<start]),
            current: String(characters[start..<end]),
            upcoming: String(characters[end...])
        )
    }
}

public struct HistoryParagraphRuns: Equatable, Sendable {
    /// Text that played before the current part.
    public let spoken: String
    /// Text that plays now.
    public let current: String
    /// Text that did not play yet, or all text when nothing is highlighted.
    public let upcoming: String

    public init(spoken: String, current: String, upcoming: String) {
        self.spoken = spoken
        self.current = current
        self.upcoming = upcoming
    }
}

extension HistoryEntry {
    /// The first sentence of the first line that is not blank, for list rows.
    public var firstSentence: String {
        let line = firstLine
        var sentence: String?
        line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { substring, _, _, stop in
            sentence = substring?.trimmingCharacters(in: .whitespaces)
            stop = true
        }
        guard let sentence, !sentence.isEmpty else { return line }
        return sentence
    }

    /// The paragraphs of the text. A paragraph ends at a blank line.
    public var paragraphs: [HistoryParagraph] {
        let characters = Array(text)
        var paragraphs: [HistoryParagraph] = []
        var start = 0
        var index = 0

        func addParagraph(endingAt end: Int) {
            var lower = start
            var upper = end
            while lower < upper, characters[lower].isWhitespace { lower += 1 }
            while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
            guard lower < upper else { return }
            paragraphs.append(
                HistoryParagraph(
                    id: paragraphs.count,
                    text: String(characters[lower..<upper]),
                    range: lower..<upper
                )
            )
        }

        while index < characters.count {
            guard characters[index].isNewline else {
                index += 1
                continue
            }
            var gapEnd = index
            var newlines = 0
            while gapEnd < characters.count, characters[gapEnd].isWhitespace {
                if characters[gapEnd].isNewline { newlines += 1 }
                gapEnd += 1
            }
            if newlines >= 2 {
                addParagraph(endingAt: index)
                start = gapEnd
            }
            index = gapEnd
        }
        addParagraph(endingAt: characters.count)
        return paragraphs
    }
}

extension HistorySource {
    /// The SF Symbol for the source.
    public var symbolName: String {
        switch self {
        case .agent: "text.bubble"
        case .clipboard: "clipboard"
        case .voicepipe: "terminal"
        }
    }
}
