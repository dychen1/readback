import Foundation
import ReadBackCore

func streamProtocolTests() -> [TestCase] {
    [
        TestCase(name: "client text append decodes from the wire contract") {
            let data = Data(#"{"type":"text.append","text":"Hello"}"#.utf8)

            let event = try JSONDecoder().decode(ReadBackClientEvent.self, from: data)

            try expectEqual(event, .textAppend("Hello"), "decoded client event")
        },
        TestCase(name: "all control events decode from their type") {
            let fixtures: [(String, ReadBackClientEvent)] = [
                (#"{"type":"input.commit"}"#, .inputCommit),
                (#"{"type":"input.done"}"#, .inputDone),
                (#"{"type":"playback.cancel"}"#, .playbackCancel),
                (#"{"type":"playback.pause"}"#, .playbackPause),
                (#"{"type":"playback.resume"}"#, .playbackResume),
            ]

            for (json, expected) in fixtures {
                let decoded = try JSONDecoder().decode(
                    ReadBackClientEvent.self,
                    from: Data(json.utf8)
                )
                try expectEqual(decoded, expected, "control event")
            }
        },
        TestCase(name: "server event encodes stable field names") {
            let event = ReadBackServerEvent(
                type: .speechStarted,
                sessionID: "session-1",
                sequence: 3,
                message: nil
            )

            let data = try JSONEncoder().encode(event)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            try expectEqual(object?["type"] as? String, "speech.started", "event type")
            try expectEqual(object?["session_id"] as? String, "session-1", "session ID")
            try expectEqual(object?["sequence"] as? Int, 3, "sequence")
            try expect(object?["message"] == nil, "nil message should be absent")
        },
        TestCase(name: "server protocol exposes every required event name") {
            try expectEqual(
                Set(ReadBackServerEvent.Kind.allCases.map(\.rawValue)),
                Set([
                    "session.ready",
                    "speech.queued",
                    "speech.started",
                    "speech.finished",
                    "queue.paused",
                    "queue.resumed",
                    "session.finished",
                    "playback.paused",
                    "playback.resumed",
                    "error",
                ]),
                "server event names"
            )
        },
    ]
}
