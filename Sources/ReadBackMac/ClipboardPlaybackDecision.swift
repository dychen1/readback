public enum ClipboardPlaybackState: Equatable, Sendable {
    case idle
    case starting
    case playing
    case paused
}

public enum ClipboardPlaybackCommand: Equatable, Sendable {
    case start(String)
    case cancelStarting
    case pause
    case resume
    case replace(String)
}

public enum ClipboardPlaybackDecision {
    public static func command(
        state: ClipboardPlaybackState,
        currentText: String?,
        clipboardText: String
    ) -> ClipboardPlaybackCommand {
        guard state != .idle else {
            return .start(clipboardText)
        }
        guard currentText == clipboardText else {
            return .replace(clipboardText)
        }
        switch state {
        case .idle:
            return .start(clipboardText)
        case .starting:
            return .cancelStarting
        case .playing:
            return .pause
        case .paused:
            return .resume
        }
    }
}
