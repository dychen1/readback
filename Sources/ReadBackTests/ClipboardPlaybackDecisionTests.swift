import ReadBackMac

func clipboardPlaybackDecisionTests() -> [TestCase] {
    [
        TestCase(name: "clipboard shortcut maps playback state and text to one command") {
            let cases: [(
                ClipboardPlaybackState,
                String?,
                String,
                ClipboardPlaybackCommand
            )] = [
                (.idle, nil, "New", .start("New")),
                (.starting, "Same", "Same", .cancelStarting),
                (.playing, "Same", "Same", .pause),
                (.paused, "Same", "Same", .resume),
                (.starting, "Old", "New", .replace("New")),
                (.playing, "Old", "New", .replace("New")),
                (.paused, "Old", "New", .replace("New")),
            ]

            for (state, currentText, clipboardText, expected) in cases {
                let command = ClipboardPlaybackDecision.command(
                    state: state,
                    currentText: currentText,
                    clipboardText: clipboardText
                )
                try expectEqual(command, expected, "decision for \(state)")
            }
        },
    ]
}
