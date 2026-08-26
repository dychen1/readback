import AppKit

public enum SystemClipboardReader {
    @MainActor
    public static func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
