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

    /// Gives speech to `sessionID`, taking over from any current speech session.
    /// Only a model switch blocks it.
    public func claimSpeech(sessionID: String) throws {
        guard state != .modelSwitch else { throw ReadBackActivityGateError.busy }
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
