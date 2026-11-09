import Foundation
import ReadBackMac

private actor StubVoicePipeSessionClient: VoicePipeSessionClient {
    private let failsToConnect: Bool
    private var finished = false
    private var finishStarted = false
    private var finishStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellations = 0

    init(failsToConnect: Bool = false) {
        self.failsToConnect = failsToConnect
    }

    var sessionID: String? { failsToConnect ? nil : "stub-session" }

    func connect() async throws {
        if failsToConnect {
            throw TestFailure(description: "forced connection failure")
        }
    }
    func append(_ text: String) async throws {}

    func finish() async throws {
        if finished { return }
        finishStarted = true
        finishStartWaiters.forEach { $0.resume() }
        finishStartWaiters.removeAll()
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func cancel() async {
        cancellations += 1
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func pause() async throws {}
    func resume() async throws {}
    func cancellationCount() -> Int { cancellations }

    func waitUntilFinishStarts() async {
        if finishStarted { return }
        await withCheckedContinuation { finishStartWaiters.append($0) }
    }
}

private final class StubVoicePipeClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any VoicePipeSessionClient]
    private var calls = 0

    init(_ clients: [any VoicePipeSessionClient]) {
        self.clients = clients
    }

    func next() -> any VoicePipeSessionClient {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return clients.removeFirst()
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor RecordingVoicePipeSessionClient: VoicePipeSessionClient {
    private(set) var appended: [String] = []

    var sessionID: String? { "recorded-session" }
    func connect() async throws {}
    func append(_ text: String) async throws { appended.append(text) }
    func finish() async throws {}
    func cancel() async {}
    func pause() async throws {}
    func resume() async throws {}
}

func voicePipeTextSpeakerTests() -> [TestCase] {
    [
        TestCase(name: "voicepipe speaker sends long text in pieces that fit one frame") {
            let client = RecordingVoicePipeSessionClient()
            let speaker = VoicePipeTextSpeaker { client }
            let text = String(repeating: "Long text with é and 👩‍👩‍👧 in it. ", count: 900)
            let readySession = SessionBox()

            try await speaker.speak(text, requestID: UUID()) { sessionID in
                await readySession.set(sessionID)
            }

            let pieces = await client.appended
            let limit = VoicePipeTextSpeaker.maximumAppendBytes
            try expect(pieces.count > 1, "long text is split, got \(pieces.count) piece(s)")
            try expect(pieces.allSatisfy { $0.utf8.count <= limit }, "each piece fits the limit")
            try expectEqual(pieces.joined(), text, "pieces keep every character in order")
            try expectEqual(
                pieces.map(\.count).reduce(0, +),
                text.count,
                "every piece boundary is a character boundary"
            )
            try expect(
                pieces.dropLast().allSatisfy { $0.last?.isWhitespace == true },
                "each piece ends after a space, not inside a word"
            )
            let session = await readySession.value
            try expectEqual(session, "recorded-session", "onReady gets the session ID")
        },
        TestCase(name: "voicepipe speaker pieces fall back to character boundaries") {
            // One character with many combining marks is larger than the limit.
            let large = "e" + String(repeating: "\u{0301}", count: 10)
            let limit = 8
            try expect(large.utf8.count > limit, "the test character is larger than the limit")

            try expectEqual(
                VoicePipeTextSpeaker.appendPieces(of: "a " + large + " b", maximumBytes: limit),
                ["a ", large, " b"],
                "a character larger than the limit goes out alone, above the limit"
            )
            try expectEqual(
                VoicePipeTextSpeaker.appendPieces(of: "abcdefghij", maximumBytes: limit),
                ["abcdefgh", "ij"],
                "text without whitespace ends a piece at the limit"
            )
        },
        TestCase(name: "stale clipboard cancellation cannot stop a newer request") {
            let oldClient = StubVoicePipeSessionClient()
            let newClient = StubVoicePipeSessionClient()
            let factory = StubVoicePipeClientFactory([oldClient, newClient])
            let speaker = VoicePipeTextSpeaker(clientFactory: { factory.next() })
            let oldRequest = UUID()
            let newRequest = UUID()

            let oldSpeech = Task {
                try await speaker.speak("old", requestID: oldRequest) { _ in }
            }
            await oldClient.waitUntilFinishStarts()
            await speaker.cancel(requestID: oldRequest)
            try await oldSpeech.value

            let newSpeech = Task {
                try await speaker.speak("new", requestID: newRequest) { _ in }
            }
            await newClient.waitUntilFinishStarts()
            await speaker.cancel(requestID: oldRequest)

            let newCancellationCount = await newClient.cancellationCount()
            try expectEqual(
                newCancellationCount,
                0,
                "an old cancellation must not target the new client"
            )

            await speaker.cancel(requestID: newRequest)
            try await newSpeech.value
        },
        TestCase(name: "failed clipboard speech closes its exact client") {
            let client = StubVoicePipeSessionClient(failsToConnect: true)
            let factory = StubVoicePipeClientFactory([client])
            let speaker = VoicePipeTextSpeaker(clientFactory: { factory.next() })

            do {
                try await speaker.speak("fails", requestID: UUID()) { _ in }
                throw TestFailure(description: "connection should fail")
            } catch let error as TestFailure {
                try expectEqual(error.description, "forced connection failure", "speech error")
            }

            let cancellationCount = await client.cancellationCount()
            try expectEqual(cancellationCount, 1, "failed client cleanup")
        },
        TestCase(name: "a pre-cancelled request never creates a voicepipe client") {
            let client = StubVoicePipeSessionClient()
            let factory = StubVoicePipeClientFactory([client])
            let speaker = VoicePipeTextSpeaker(clientFactory: { factory.next() })
            let requestID = UUID()

            let speech = Task {
                do {
                    try await wait(for: .seconds(10))
                } catch {
                }
                try await speaker.speak("cancelled", requestID: requestID) { _ in }
            }
            speech.cancel()

            do {
                try await speech.value
                throw TestFailure(description: "pre-cancelled speech should fail")
            } catch is CancellationError {
            }
            try expectEqual(factory.callCount(), 0, "client factory calls")
        },
    ]
}

private actor SessionBox {
    private(set) var value: String?
    func set(_ value: String?) { self.value = value }
}
