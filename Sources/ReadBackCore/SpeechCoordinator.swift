import Foundation

public protocol AudioPlaying: Sendable {
    func play(_ clip: AudioClip) async throws
    func stop() async
    func pause() async
    func resume() async
}

public enum SpeechCoordinatorError: Error, Equatable, Sendable {
    case sessionAlreadyActive
    case noActiveSession
    case queueLimitExceeded
}

public actor SpeechCoordinator {
    public typealias EventSink = @Sendable (ReadBackServerEvent) async -> Void

    private struct Segment: Sendable {
        let sequence: Int
        let text: String
        let voice: String
        let speed: Double
    }

    private let synthesizer: any SpeechSynthesizing
    private let player: any AudioPlaying
    private let modelPath: URL
    private let maximumPendingCharacters: Int

    private var sessionID: String?
    private var sessionGeneration = 0
    private var isEndingSession = false
    private var eventSink: EventSink?
    private var queue: [Segment] = []
    private var nextSequence = 0
    private var pendingCharacters = 0
    private var inputFinished = false
    private var queuePaused = false
    private var playbackPaused = false
    private var worker: Task<Void, Never>?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        synthesizer: any SpeechSynthesizing,
        player: any AudioPlaying,
        modelPath: URL,
        maximumPendingCharacters: Int = 2_000
    ) {
        precondition(maximumPendingCharacters > 0)
        self.synthesizer = synthesizer
        self.player = player
        self.modelPath = modelPath
        self.maximumPendingCharacters = maximumPendingCharacters
    }

    public var hasActiveSession: Bool {
        sessionID != nil
    }

    public var isPaused: Bool {
        playbackPaused
    }

    public func startSession(id: String, events: @escaping EventSink) async throws {
        guard sessionID == nil else {
            throw SpeechCoordinatorError.sessionAlreadyActive
        }
        sessionID = id
        sessionGeneration += 1
        isEndingSession = false
        eventSink = events
        queue.removeAll(keepingCapacity: true)
        nextSequence = 0
        pendingCharacters = 0
        inputFinished = false
        queuePaused = false
        playbackPaused = false
        await events(ReadBackServerEvent(type: .sessionReady, sessionID: id))
    }

    @discardableResult
    public func enqueue(text: String, voice: String, speed: Double) async throws -> Int {
        guard let sessionID, let eventSink else {
            throw SpeechCoordinatorError.noActiveSession
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nextSequence
        }
        guard pendingCharacters + normalized.count <= maximumPendingCharacters else {
            if !queuePaused {
                queuePaused = true
                await eventSink(ReadBackServerEvent(type: .queuePaused, sessionID: sessionID))
            }
            throw SpeechCoordinatorError.queueLimitExceeded
        }

        let sequence = nextSequence
        nextSequence += 1
        pendingCharacters += normalized.count
        queue.append(
            Segment(sequence: sequence, text: normalized, voice: voice, speed: speed)
        )
        await eventSink(
            ReadBackServerEvent(type: .speechQueued, sessionID: sessionID, sequence: sequence)
        )
        startWorkerIfNeeded(sessionID: sessionID)
        return sequence
    }

    public func finishInput() async {
        guard let sessionID else {
            return
        }
        inputFinished = true
        if queue.isEmpty, worker == nil {
            await completeSession(id: sessionID)
        }
    }

    public func waitUntilFinished(sessionID expectedSessionID: String) async {
        guard sessionID == expectedSessionID else {
            return
        }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    public func cancel() async {
        guard let activeID = sessionID, !isEndingSession else {
            return
        }
        let sink = eventSink
        isEndingSession = true
        sessionGeneration += 1
        worker?.cancel()
        worker = nil
        queue.removeAll(keepingCapacity: true)
        pendingCharacters = 0
        inputFinished = true
        playbackPaused = false
        resumePauseWaiters()
        await player.stop()
        if let sink {
            await sink(ReadBackServerEvent(type: .sessionFinished, sessionID: activeID))
        }
        guard sessionID == activeID else { return }
        sessionID = nil
        eventSink = nil
        isEndingSession = false
        resumeCompletionWaiters()
    }

    public func pause() async {
        guard let sessionID, let eventSink, !playbackPaused, !isEndingSession else { return }
        let generation = sessionGeneration
        playbackPaused = true
        await player.pause()
        guard self.sessionID == sessionID,
              sessionGeneration == generation,
              playbackPaused,
              !isEndingSession
        else { return }
        await eventSink(ReadBackServerEvent(type: .playbackPaused, sessionID: sessionID))
    }

    public func resume() async {
        guard let sessionID, let eventSink, playbackPaused, !isEndingSession else { return }
        let generation = sessionGeneration
        playbackPaused = false
        await player.resume()
        guard self.sessionID == sessionID,
              sessionGeneration == generation,
              !playbackPaused,
              !isEndingSession
        else { return }
        resumePauseWaiters()
        await eventSink(ReadBackServerEvent(type: .playbackResumed, sessionID: sessionID))
    }

    private func startWorkerIfNeeded(sessionID: String) {
        guard worker == nil else {
            return
        }
        worker = Task { [weak self] in
            await self?.processQueue(sessionID: sessionID)
        }
    }

    private func processQueue(sessionID expectedSessionID: String) async {
        while !Task.isCancelled {
            await waitUntilResumed()
            guard sessionID == expectedSessionID, let sink = eventSink else {
                return
            }
            guard !queue.isEmpty else {
                worker = nil
                if inputFinished {
                    await completeSession(id: expectedSessionID)
                }
                return
            }

            let segment = queue.removeFirst()
            await sink(
                ReadBackServerEvent(
                    type: .speechStarted,
                    sessionID: expectedSessionID,
                    sequence: segment.sequence
                )
            )

            do {
                let clip = try await synthesizer.synthesize(
                    SpeechRequest(
                        input: segment.text,
                        voice: segment.voice,
                        speed: segment.speed,
                        format: .wav
                    ),
                    modelPath: modelPath
                )
                try Task.checkCancellation()
                await waitUntilResumed()
                try Task.checkCancellation()
                guard sessionID == expectedSessionID else { return }
                try await player.play(clip)
                try Task.checkCancellation()
                pendingCharacters -= segment.text.count
                await sink(
                    ReadBackServerEvent(
                        type: .speechFinished,
                        sessionID: expectedSessionID,
                        sequence: segment.sequence
                    )
                )
                if queuePaused, pendingCharacters < maximumPendingCharacters {
                    queuePaused = false
                    await sink(ReadBackServerEvent(type: .queueResumed, sessionID: expectedSessionID))
                }
            } catch is CancellationError {
                return
            } catch {
                pendingCharacters -= segment.text.count
                await sink(
                    ReadBackServerEvent(
                        type: .error,
                        sessionID: expectedSessionID,
                        sequence: segment.sequence,
                        message: String(describing: error)
                    )
                )
            }
        }
    }

    private func completeSession(id: String) async {
        guard sessionID == id, !isEndingSession else {
            return
        }
        let sink = eventSink
        let generation = sessionGeneration
        isEndingSession = true
        worker = nil
        playbackPaused = false
        resumePauseWaiters()
        if let sink {
            await sink(ReadBackServerEvent(type: .sessionFinished, sessionID: id))
        }
        guard sessionID == id, sessionGeneration == generation else { return }
        sessionID = nil
        eventSink = nil
        isEndingSession = false
        resumeCompletionWaiters()
    }

    private func resumeCompletionWaiters() {
        let waiters = completionWaiters
        completionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitUntilResumed() async {
        while playbackPaused {
            await withCheckedContinuation { pauseWaiters.append($0) }
        }
    }

    private func resumePauseWaiters() {
        let waiters = pauseWaiters
        pauseWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}
