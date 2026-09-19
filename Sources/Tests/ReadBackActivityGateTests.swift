import Foundation
import ReadBackCore

func readBackActivityGateTests() -> [TestCase] {
    [
        TestCase(name: "activity gate blocks a model switch during speech") {
            let gate = ReadBackActivityGate()
            try await gate.beginSpeech(sessionID: "speech-1")

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
        TestCase(name: "activity gate ignores a stale speech release") {
            let gate = ReadBackActivityGate()
            try await gate.beginSpeech(sessionID: "current")

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
