import Foundation
import VoicePipeKit

public protocol VoicePipeSessionClient: Sendable {
    func connect() async throws
    func append(_ text: String) async throws
    func finish() async throws
    func cancel() async
    func pause() async throws
    func resume() async throws
}

extension VoicePipeClient: VoicePipeSessionClient {}

public actor VoicePipeTextSpeaker: ClipboardSpeechPlaying {
    public typealias ClientFactory = @Sendable () -> any VoicePipeSessionClient

    private struct ActiveSession: Sendable {
        let requestID: UUID
        let client: any VoicePipeSessionClient
    }

    private let clientFactory: ClientFactory
    private var activeSession: ActiveSession?
    private var cancellationTasks: [UUID: Task<Void, Never>] = [:]

    public init(endpoint: URL) {
        clientFactory = { VoicePipeClient(endpoint: endpoint) }
    }

    public init(clientFactory: @escaping ClientFactory) {
        self.clientFactory = clientFactory
    }

    public func cancel() async {
        guard let activeSession else { return }
        await cancel(activeSession)
    }

    public func cancel(requestID: UUID) async {
        if let cancellationTask = cancellationTasks[requestID] {
            await cancellationTask.value
            return
        }
        guard let activeSession, activeSession.requestID == requestID else { return }
        await cancel(activeSession)
    }

    private func cancel(_ session: ActiveSession) async {
        self.activeSession = nil
        let task = Task { await session.client.cancel() }
        cancellationTasks[session.requestID] = task
        await task.value
        cancellationTasks[session.requestID] = nil
    }

    public func speak(_ text: String) async throws {
        try await speak(text, requestID: UUID()) {}
    }

    public func speak(
        _ text: String,
        requestID: UUID,
        onReady: @escaping @Sendable () async -> Void
    ) async throws {
        try Task.checkCancellation()
        let client = clientFactory()
        activeSession = ActiveSession(requestID: requestID, client: client)

        do {
            try await client.connect()
            try await client.append(text)
            try Task.checkCancellation()
            await onReady()
            try await client.finish()
            clear(requestID: requestID)
        } catch {
            await client.cancel()
            clear(requestID: requestID)
            throw error
        }
    }

    public func pause() async throws -> Bool {
        guard let activeSession else { return false }
        try await activeSession.client.pause()
        return true
    }

    public func pause(requestID: UUID) async throws -> Bool {
        guard let activeSession, activeSession.requestID == requestID else { return false }
        try await activeSession.client.pause()
        return true
    }

    public func resume() async throws -> Bool {
        guard let activeSession else { return false }
        try await activeSession.client.resume()
        return true
    }

    public func resume(requestID: UUID) async throws -> Bool {
        guard let activeSession, activeSession.requestID == requestID else { return false }
        try await activeSession.client.resume()
        return true
    }

    private func clear(requestID: UUID) {
        guard activeSession?.requestID == requestID else { return }
        activeSession = nil
    }
}
