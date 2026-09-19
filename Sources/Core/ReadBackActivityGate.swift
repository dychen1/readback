import Foundation

public enum ReadBackActivityGateError: Error, Equatable, Sendable {
    case busy
}

public actor ReadBackActivityGate {
    public enum State: Equatable, Sendable {
        case idle
        case speech(sessionID: String)
        case modelSwitch
    }

    private var state: State = .idle

    public init() {}

    public func currentState() -> State { state }

    public func beginSpeech(sessionID: String) throws {
        guard state == .idle else { throw ReadBackActivityGateError.busy }
        state = .speech(sessionID: sessionID)
    }

    public func endSpeech(sessionID: String) {
        guard state == .speech(sessionID: sessionID) else { return }
        state = .idle
    }

    public func beginModelSwitch() throws {
        guard state == .idle else { throw ReadBackActivityGateError.busy }
        state = .modelSwitch
    }

    public func endModelSwitch() {
        guard state == .modelSwitch else { return }
        state = .idle
    }
}
