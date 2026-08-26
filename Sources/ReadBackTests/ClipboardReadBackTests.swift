import Foundation
import ReadBackMac

private enum RecordedClipboardSpeechEvent: Equatable {
    case cancelled
    case spoke(String)
}

private actor RecordingClipboardSpeaker: ClipboardSpeechPlaying {
    private var events: [RecordedClipboardSpeechEvent] = []

    func cancel() async {
        events.append(.cancelled)
    }

    func speak(_ text: String) async throws {
        events.append(.spoke(text))
    }

    func recordedEvents() -> [RecordedClipboardSpeechEvent] {
        events
    }
}

private actor PausingClipboardSpeaker: ClipboardSpeechPlaying {
    private var events: [RecordedClipboardSpeechEvent] = []
    private var cancelStarted = false
    private var cancelStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelRelease: CheckedContinuation<Void, Never>?

    func cancel() async {
        events.append(.cancelled)
        cancelStarted = true
        cancelStartedWaiters.forEach { $0.resume() }
        cancelStartedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            cancelRelease = continuation
        }
    }

    func speak(_ text: String) async throws {
        events.append(.spoke(text))
    }

    func waitUntilCancelStarts() async {
        if cancelStarted {
            return
        }
        await withCheckedContinuation { continuation in
            cancelStartedWaiters.append(continuation)
        }
    }

    func releaseCancel() {
        cancelRelease?.resume()
        cancelRelease = nil
    }

    func recordedEvents() -> [RecordedClipboardSpeechEvent] {
        events
    }
}

func clipboardReadBackTests() -> [TestCase] {
    [
        TestCase(name: "clipboard read-back trims text and replaces active speech") {
            let speaker = RecordingClipboardSpeaker()
            let action = ClipboardReadBackAction(speaker: speaker, maximumCharacters: 2_000)

            let result = try await action.perform(text: "  Hello from the clipboard.\n")

            try expectEqual(result, .spoken(characterCount: 25), "spoken result")
            let events = await speaker.recordedEvents()
            try expectEqual(
                events,
                [.cancelled, .spoke("Hello from the clipboard.")],
                "speech replacement order"
            )
        },
        TestCase(name: "clipboard read-back rejects a missing text value") {
            let speaker = RecordingClipboardSpeaker()
            let action = ClipboardReadBackAction(speaker: speaker, maximumCharacters: 2_000)

            do {
                _ = try await action.perform(text: nil)
                throw TestFailure(description: "missing clipboard text should fail")
            } catch let error as ClipboardReadBackError {
                try expectEqual(error, .noText, "missing text error")
            }
            let events = await speaker.recordedEvents()
            try expectEqual(events, [], "speech should not start")
        },
        TestCase(name: "clipboard read-back rejects whitespace-only text") {
            let speaker = RecordingClipboardSpeaker()
            let action = ClipboardReadBackAction(speaker: speaker, maximumCharacters: 2_000)

            do {
                _ = try await action.perform(text: " \n\t ")
                throw TestFailure(description: "blank clipboard text should fail")
            } catch let error as ClipboardReadBackError {
                try expectEqual(error, .noText, "blank text error")
            }
            let events = await speaker.recordedEvents()
            try expectEqual(events, [], "speech should not start")
        },
        TestCase(name: "clipboard read-back enforces its pending text limit") {
            let speaker = RecordingClipboardSpeaker()
            let action = ClipboardReadBackAction(speaker: speaker, maximumCharacters: 5)

            _ = try await action.perform(text: "12345")
            do {
                _ = try await action.perform(text: "123456")
                throw TestFailure(description: "oversized clipboard text should fail")
            } catch let error as ClipboardReadBackError {
                try expectEqual(
                    error,
                    .tooLong(actual: 6, maximum: 5),
                    "oversized text error"
                )
            }
            let events = await speaker.recordedEvents()
            try expectEqual(
                events,
                [.cancelled, .spoke("12345")],
                "oversized text should not replace speech"
            )
        },
        TestCase(name: "a cancelled clipboard action cannot start stale speech") {
            let speaker = PausingClipboardSpeaker()
            let action = ClipboardReadBackAction(speaker: speaker, maximumCharacters: 2_000)
            let task = Task {
                try await action.perform(text: "Old clipboard text")
            }

            await speaker.waitUntilCancelStarts()
            task.cancel()
            await speaker.releaseCancel()

            do {
                _ = try await task.value
                throw TestFailure(description: "cancelled clipboard action should stop")
            } catch is CancellationError {
            }
            let events = await speaker.recordedEvents()
            try expectEqual(events, [.cancelled], "cancelled action events")
        },
    ]
}
