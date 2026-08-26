import Foundation
import ReadBackCore

public protocol VoicePipeSocket: Sendable {
    func resume() async
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close() async
}

private final class URLSessionVoicePipeSocket: VoicePipeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(endpoint: URL, session: URLSession) {
        task = session.webSocketTask(with: endpoint)
    }

    func resume() async {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public struct VoicePipeArguments: Equatable, Sendable {
    public let endpoint: URL

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }

    public static func parse(_ arguments: [String]) throws -> VoicePipeArguments {
        if let index = arguments.firstIndex(of: "--url"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]) {
            return VoicePipeArguments(endpoint: url)
        }
        return VoicePipeArguments(
            endpoint: URL(string: "ws://127.0.0.1:51280/v1/readback/stream")!
        )
    }
}

public enum VoicePipeError: Error, Sendable {
    case invalidServerMessage
    case server(String)
    case disconnected
}

public actor VoicePipeClient {
    private let socket: any VoicePipeSocket
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let idleDelay: Duration
    private var idleCommit: Task<Void, Never>?
    private var receiver: Task<Void, Error>?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReady = false
    private var isFinished = false
    private var isPaused = false
    private var receiverTerminated = false
    private var serverError: String?

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        idleDelay: Duration = .milliseconds(300)
    ) {
        self.socket = URLSessionVoicePipeSocket(endpoint: endpoint, session: session)
        self.idleDelay = idleDelay
    }

    public init(
        socket: any VoicePipeSocket,
        idleDelay: Duration = .milliseconds(300)
    ) {
        self.socket = socket
        self.idleDelay = idleDelay
    }

    public func connect() async throws {
        await socket.resume()
        receiver = Task { [weak self] in
            try await self?.receiveEvents()
        }
        if !isReady {
            await withCheckedContinuation { readyWaiters.append($0) }
        }
        try requireLiveReceiver(unlessFinished: false)
    }

    public func append(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try await send(.textAppend(text))
        idleCommit?.cancel()
        idleCommit = Task { [weak self, idleDelay] in
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled else { return }
            try? await self?.send(.inputCommit)
        }
    }

    public func finish() async throws {
        idleCommit?.cancel()
        try await send(.inputDone)
        try requireLiveReceiver(unlessFinished: true)
        if !isFinished {
            await withCheckedContinuation { finishedWaiters.append($0) }
        }
        if let serverError {
            throw VoicePipeError.server(serverError)
        }
        await socket.close()
        _ = try? await receiver?.value
    }

    public func cancel() async {
        idleCommit?.cancel()
        if !isFinished {
            do {
                try await send(.playbackCancel)
                if !isFinished, !receiverTerminated {
                    await withCheckedContinuation { finishedWaiters.append($0) }
                }
            } catch {
                serverError = String(describing: error)
            }
        }
        await socket.close()
        _ = try? await receiver?.value
    }

    public func pause() async throws {
        guard !isFinished else { throw VoicePipeError.disconnected }
        try await send(.playbackPause)
        try requireLiveReceiver(unlessFinished: false)
        if !isPaused {
            await withCheckedContinuation { pausedWaiters.append($0) }
        }
        if let serverError { throw VoicePipeError.server(serverError) }
        guard isPaused else { throw VoicePipeError.disconnected }
    }

    public func resume() async throws {
        guard !isFinished else { throw VoicePipeError.disconnected }
        try await send(.playbackResume)
        try requireLiveReceiver(unlessFinished: false)
        if isPaused {
            await withCheckedContinuation { resumedWaiters.append($0) }
        }
        if let serverError { throw VoicePipeError.server(serverError) }
        guard !isPaused else { throw VoicePipeError.disconnected }
    }

    private func send(_ event: ReadBackClientEvent) async throws {
        let data = try encoder.encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoicePipeError.invalidServerMessage
        }
        try await socket.send(.string(text))
    }

    private func receiveEvents() async throws {
        do {
            while true {
                let message = try await socket.receive()
                guard case .string(let text) = message else { continue }
                let event = try decoder.decode(ReadBackServerEvent.self, from: Data(text.utf8))
                switch event.type {
                case .sessionReady:
                    isReady = true
                    resume(&readyWaiters)
                case .sessionFinished:
                    isFinished = true
                    receiverTerminated = true
                    resume(&readyWaiters)
                    resume(&finishedWaiters)
                    resume(&pausedWaiters)
                    resume(&resumedWaiters)
                    return
                case .playbackPaused:
                    isPaused = true
                    resume(&pausedWaiters)
                case .playbackResumed:
                    isPaused = false
                    resume(&resumedWaiters)
                case .error:
                    serverError = event.message ?? "Read-back service error"
                default:
                    continue
                }
            }
        } catch {
            serverError = String(describing: error)
            receiverTerminated = true
            resume(&readyWaiters)
            resume(&finishedWaiters)
            resume(&pausedWaiters)
            resume(&resumedWaiters)
            throw error
        }
    }

    private func requireLiveReceiver(unlessFinished: Bool) throws {
        if let serverError {
            throw VoicePipeError.server(serverError)
        }
        if receiverTerminated, !(unlessFinished && isFinished) {
            throw VoicePipeError.disconnected
        }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        pending.forEach { $0.resume() }
    }
}
