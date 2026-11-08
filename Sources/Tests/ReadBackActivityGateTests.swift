import Foundation
import ReadBackCore

func readBackActivityGateTests() -> [TestCase] {
    [
        TestCase(name: "activity gate blocks a model switch during speech") {
            let gate = ReadBackActivityGate()
            try await gate.claimSpeech(sessionID: "speech-1")

            do {
                try await gate.beginModelSwitch()
                throw TestFailure(description: "switch should be blocked")
            } catch let error as ReadBackActivityGateError {
                try expectEqual(error, .busy, "gate error")
            }

            await gate.endSpeech(sessionID: "speech-1")
            try await gate.beginModelSwitch()
            await gate.endModelSwitch()
            let state = await gate.currentState()
            try expectEqual(state, .idle, "released state")
        },
        TestCase(name: "activity gate hands speech to a newer session") {
            let gate = ReadBackActivityGate()
            try await gate.claimSpeech(sessionID: "old")
            try await gate.claimSpeech(sessionID: "new")

            await gate.endSpeech(sessionID: "old")
            let state = await gate.currentState()
            try expectEqual(state, .speech(sessionID: "new"), "old release leaves the new owner")
        },
        TestCase(name: "activity gate blocks speech during a model switch") {
            let gate = ReadBackActivityGate()
            try await gate.beginModelSwitch()

            do {
                try await gate.claimSpeech(sessionID: "too-early")
                throw TestFailure(description: "speech should be blocked")
            } catch let error as ReadBackActivityGateError {
                try expectEqual(error, .busy, "gate error")
            }
            let state = await gate.currentState()
            try expectEqual(state, .modelSwitch, "switch keeps the gate")
        },
        TestCase(name: "activity gate ignores a stale speech release") {
            let gate = ReadBackActivityGate()
            try await gate.claimSpeech(sessionID: "current")

            await gate.endSpeech(sessionID: "stale")
            let state = await gate.currentState()

            try expectEqual(
                state,
                .speech(sessionID: "current"),
                "active speech remains"
            )
        },
    ]
}
