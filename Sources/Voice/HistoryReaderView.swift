import AppKit
import ReadBackCore
import SwiftUI

/// Shows the full text of one entry for reading.
struct HistoryReaderView: View {
    let entry: HistoryEntry
    /// The part of the entry that plays now, as character offsets. It stays `nil` until
    /// playback reports its progress. The reader shows no highlight for `nil`.
    let spokenRange: Range<Int>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let paragraphs = entry.paragraphs
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(paragraphs) { paragraph in
                            Text(attributedText(paragraph))
                                .font(.system(size: 17))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(paragraph.id)
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(insets(forWidth: proxy.size.width))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: playingParagraphID(in: paragraphs)) { _, id in
                    guard let id else { return }
                    if reduceMotion {
                        scroller.scrollTo(id, anchor: .top)
                    } else {
                        withAnimation { scroller.scrollTo(id, anchor: .top) }
                    }
                }
            }
        }
        .id(entry.id)
    }

    private func attributedText(_ paragraph: HistoryParagraph) -> AttributedString {
        let runs = paragraph.runs(spokenRange: spokenRange)
        var spoken = AttributedString(runs.spoken)
        spoken.foregroundColor = Color.historySpokenText
        var current = AttributedString(runs.current)
        current.backgroundColor = Color.accentColor.opacity(contrast == .increased ? 0.25 : 0.13)
        if differentiateWithoutColor {
            current.underlineStyle = .single
        }
        var text = spoken
        text.append(current)
        text.append(AttributedString(runs.upcoming))
        return text
    }

    private func playingParagraphID(in paragraphs: [HistoryParagraph]) -> Int? {
        guard let spokenRange else { return nil }
        return paragraphs.first { $0.range.contains(spokenRange.lowerBound) }?.id
    }

    private func insets(forWidth width: CGFloat) -> EdgeInsets {
        let side: CGFloat = width < 400 ? 20 : 36
        return EdgeInsets(top: 26, leading: side, bottom: 32, trailing: side)
    }
}

/// A thin accent line under the toolbar that shows how much of the entry played.
struct HistoryProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.tint)
                .frame(width: proxy.size.width * value)
        }
        .frame(height: 2)
        .accessibilityElement()
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// The keyboard hints under the reader, or the last replay error.
struct HistoryHintBar: View {
    let voiceName: String
    let error: String?

    private enum Key {
        case symbol(String)
        case text(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(error)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    allHints
                    Spacer(minLength: 12)
                    Text("Replays use \(voiceName)")
                }
                HStack(spacing: 14) {
                    allHints
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    hint([.text("Space")], "Play or stop")
                    hint([.text("esc")], "Stop")
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Keyboard shortcuts. Up Arrow and Down Arrow move the selection. Space plays or stops. Delete removes the entry. Escape stops playback. Replays use \(voiceName)."
            )
        }
    }

    @ViewBuilder
    private var allHints: some View {
        hint([.symbol("arrow.up"), .symbol("arrow.down")], "Move")
        hint([.text("Space")], "Play or stop")
        hint([.symbol("delete.left")], "Delete")
        hint([.text("esc")], "Stop")
    }

    private func hint(_ keys: [Key], _ action: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keycap(key)
            }
            Text(action)
                .fixedSize()
        }
    }

    private func keycap(_ key: Key) -> some View {
        Group {
            switch key {
            case .symbol(let name):
                Image(systemName: name).imageScale(.small)
            case .text(let label):
                Text(label)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 4)
        .frame(minWidth: 18, minHeight: 16)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }
}

extension Color {
    /// The gray of text that already played. The system secondary label color is about 3.9:1
    /// on white, which fails WCAG AA for 17 pt text. This gray is about 5.0:1 in light mode and
    /// about 5.8:1 in dark mode.
    static let historySpokenText = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x98 / 255, green: 0x98 / 255, blue: 0x9D / 255, alpha: 1)
                : NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
        }
    )
}
