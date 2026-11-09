import Foundation
import VoicePipeKit

public protocol VoicePipeSessionClient: Sendable {
    var sessionID: String? { get async }
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

    /// The most UTF-8 bytes of text that one `text.append` message carries. JSON escapes can
    /// make a message up to six times larger, and the server accepts frames up to 16 KB.
    public static let maximumAppendBytes = 2_000

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
        try await speak(text, requestID: UUID()) { _ in }
    }

    /// Reads `text` and returns when the reading ends. `onReady` gets the server's session ID
    /// of the reading after the server accepts the text.
    public func speak(
        _ text: String,
        requestID: UUID,
        onReady: @escaping @Sendable (_ sessionID: String?) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let client = clientFactory()
        activeSession = ActiveSession(requestID: requestID, client: client)

        do {
            try await client.connect()
            for piece in Self.appendPieces(of: text) {
                try await client.append(piece)
            }
            try Task.checkCancellation()
            await onReady(await client.sessionID)
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

    /// Splits `text` into pieces of at most `maximumBytes` UTF-8 bytes. A piece ends after the
    /// last whitespace that fits, so the server does not see a word cut in two. A piece with no
    /// whitespace ends at a character boundary. A single character that is larger than the limit
    /// goes out alone, above the limit, because a character cannot be split.
    public static func appendPieces(of text: String, maximumBytes: Int = maximumAppendBytes) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        var bytes = 0
        // The end of the last whitespace in the current piece, and the piece size up to it.
        var lastBreak: (index: String.Index, bytes: Int)?
        while index < text.endIndex {
            let character = text[index]
            let size = character.utf8.count
            if bytes + size > maximumBytes, start < index {
                let end = lastBreak?.index ?? index
                pieces.append(String(text[start..<end]))
                bytes -= lastBreak?.bytes ?? bytes
                start = end
                lastBreak = nil
                continue
            }
            bytes += size
            index = text.index(after: index)
            if character.isWhitespace {
                lastBreak = (index, bytes)
            }
        }
        if start < text.endIndex {
            pieces.append(String(text[start...]))
        }
        return pieces
    }

    private func clear(requestID: UUID) {
        guard activeSession?.requestID == requestID else { return }
        activeSession = nil
    }
}
