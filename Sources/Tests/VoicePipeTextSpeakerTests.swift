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

func voicePipeTextSpeakerTests() -> [TestCase] {
    [
        TestCase(name: "stale clipboard cancellation cannot stop a newer request") {
            let oldClient = StubVoicePipeSessionClient()
            let newClient = StubVoicePipeSessionClient()
            let factory = StubVoicePipeClientFactory([oldClient, newClient])
            let speaker = VoicePipeTextSpeaker(clientFactory: { factory.next() })
            let oldRequest = UUID()
            let newRequest = UUID()

            let oldSpeech = Task {
                try await speaker.speak("old", requestID: oldRequest) {}
            }
            await oldClient.waitUntilFinishStarts()
            await speaker.cancel(requestID: oldRequest)
            try await oldSpeech.value

            let newSpeech = Task {
                try await speaker.speak("new", requestID: newRequest) {}
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
                try await speaker.speak("fails", requestID: UUID()) {}
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
                try await speaker.speak("cancelled", requestID: requestID) {}
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
