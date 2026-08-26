import Foundation
import ReadBackCore
import VoicePipeKit

private actor ControlledVoicePipeSocket: VoicePipeSocket {
    private var incoming: [URLSessionWebSocketTask.Message] = []
    private var incomingWaiters: [
        CheckedContinuation<URLSessionWebSocketTask.Message, any Error>
    ] = []
    private var sentEvents: [ReadBackClientEvent] = []
    private var sentWaiters: [CheckedContinuation<ReadBackClientEvent, Never>] = []
    private var shouldSuspendNextSend = false
    private var sendRelease: CheckedContinuation<Void, Never>?
    private var closed = false

    func resume() async {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else {
            throw TestFailure(description: "expected a text client event")
        }
        let event = try JSONDecoder().decode(ReadBackClientEvent.self, from: Data(text.utf8))
        if sentWaiters.isEmpty {
            sentEvents.append(event)
        } else {
            sentWaiters.removeFirst().resume(returning: event)
        }
        if shouldSuspendNextSend {
            shouldSuspendNextSend = false
            await withCheckedContinuation { sendRelease = $0 }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            incomingWaiters.append(continuation)
        }
    }

    func close() async {
        closed = true
    }

    func enqueue(_ event: ReadBackServerEvent) throws {
        let data = try JSONEncoder().encode(event)
        let message = URLSessionWebSocketTask.Message.string(String(decoding: data, as: UTF8.self))
        if incomingWaiters.isEmpty {
            incoming.append(message)
        } else {
            incomingWaiters.removeFirst().resume(returning: message)
        }
    }

    func failReceive() {
        let waiters = incomingWaiters
        incomingWaiters.removeAll()
        waiters.forEach {
            $0.resume(throwing: TestFailure(description: "forced disconnect"))
        }
    }

    func suspendNextSend() {
        shouldSuspendNextSend = true
    }

    func releaseSend() {
        sendRelease?.resume()
        sendRelease = nil
    }

    func nextSentEvent() async -> ReadBackClientEvent {
        if !sentEvents.isEmpty {
            return sentEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            sentWaiters.append(continuation)
        }
    }

    func isClosed() -> Bool {
        closed
    }
}

private actor CompletionProbe {
    private var result: Bool?

    func finish(_ result: Bool) {
        self.result = result
    }

    func value() -> Bool? {
        result
    }
}

func voicePipeTests() -> [TestCase] {
    [
        TestCase(name: "voicepipe uses the reserved local endpoint") {
            let arguments = try VoicePipeArguments.parse([])
            try expectEqual(
                arguments.endpoint.absoluteString,
                "ws://127.0.0.1:51280/v1/readback/stream",
                "default endpoint"
            )
        },
        TestCase(name: "voicepipe accepts an endpoint override") {
            let arguments = try VoicePipeArguments.parse(["--url", "ws://127.0.0.1:55555/ws"])
            try expectEqual(
                arguments.endpoint.absoluteString,
                "ws://127.0.0.1:55555/ws",
                "override endpoint"
            )
        },
        TestCase(name: "voicepipe cancellation waits for the server session to finish") {
            let socket = ControlledVoicePipeSocket()
            try await socket.enqueue(
                ReadBackServerEvent(type: .sessionReady, sessionID: "session-1")
            )
            let client = VoicePipeClient(socket: socket)
            try await client.connect()

            let cancellation = Task { await client.cancel() }
            let event = await socket.nextSentEvent()
            try expectEqual(event, .playbackCancel, "cancel event")
            let closedBeforeAcknowledgment = await socket.isClosed()
            try expect(
                !closedBeforeAcknowledgment,
                "socket must stay open for cancellation acknowledgment"
            )

            try await socket.enqueue(
                ReadBackServerEvent(type: .sessionFinished, sessionID: "session-1")
            )
            await cancellation.value
            let closedAfterAcknowledgment = await socket.isClosed()
            try expect(closedAfterAcknowledgment, "socket should close after session finished")
        },
        TestCase(name: "voicepipe pause and resume wait for server acknowledgements") {
            let socket = ControlledVoicePipeSocket()
            try await socket.enqueue(
                ReadBackServerEvent(type: .sessionReady, sessionID: "session-2")
            )
            let client = VoicePipeClient(socket: socket)
            try await client.connect()

            let pause = Task { try await client.pause() }
            let pauseEvent = await socket.nextSentEvent()
            try expectEqual(pauseEvent, .playbackPause, "pause event")
            try await socket.enqueue(
                ReadBackServerEvent(type: .playbackPaused, sessionID: "session-2")
            )
            try await pause.value

            let resume = Task { try await client.resume() }
            let resumeEvent = await socket.nextSentEvent()
            try expectEqual(resumeEvent, .playbackResume, "resume event")
            try await socket.enqueue(
                ReadBackServerEvent(type: .playbackResumed, sessionID: "session-2")
            )
            try await resume.value

            let cancellation = Task { await client.cancel() }
            _ = await socket.nextSentEvent()
            try await socket.enqueue(
                ReadBackServerEvent(type: .sessionFinished, sessionID: "session-2")
            )
            await cancellation.value
        },
        TestCase(name: "voicepipe pause fails if the receiver disconnects during send") {
            let socket = ControlledVoicePipeSocket()
            try await socket.enqueue(
                ReadBackServerEvent(type: .sessionReady, sessionID: "session-3")
            )
            let client = VoicePipeClient(socket: socket)
            try await client.connect()
            await socket.suspendNextSend()

            let completion = CompletionProbe()
            Task {
                do {
                    try await client.pause()
                    await completion.finish(false)
                } catch {
                    await completion.finish(true)
                }
            }
            let event = await socket.nextSentEvent()
            try expectEqual(event, .playbackPause, "pause event")
            await socket.failReceive()
            try await Task.sleep(for: .milliseconds(20))
            await socket.releaseSend()

            try await Task.sleep(for: .milliseconds(100))
            let completed = await completion.value()
            try expectEqual(completed, true, "pause should fail instead of waiting forever")
        },
    ]
}
