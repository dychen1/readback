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
        let voice: String?
        let languageCode: String?
        let speed: Double
        let pauseBefore: Double
    }

    private let synthesizer: any SpeechSynthesizing
    private let player: any AudioPlaying
    private let activityGate: ReadBackActivityGate?
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
    private var replayCache: SpeechReplayCache
    private var replayRecordingID: UUID?

    public init(
        synthesizer: any SpeechSynthesizing,
        player: any AudioPlaying,
        activityGate: ReadBackActivityGate? = nil,
        maximumPendingCharacters: Int = 2_000,
        replayCache: SpeechReplayCache = SpeechReplayCache()
    ) {
        precondition(maximumPendingCharacters > 0)
        self.synthesizer = synthesizer
        self.player = player
        self.activityGate = activityGate
        self.maximumPendingCharacters = maximumPendingCharacters
        self.replayCache = replayCache
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
        do {
            try await activityGate?.beginSpeech(sessionID: id)
        } catch {
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
        replayRecordingID = replayCache.beginRecording()
        await events(ReadBackServerEvent(type: .sessionReady, sessionID: id))
    }

    /// Drops saved and pending replay data without stopping active playback.
    public func invalidateReplayCache() {
        replayCache.invalidate()
    }

    @discardableResult
    public func enqueue(
        text: String,
        voice: String?,
        languageCode: String? = nil,
        speed: Double,
        pauseBefore: Double = 0
    ) async throws -> Int {
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
            Segment(
                sequence: sequence,
                text: normalized,
                voice: voice,
                languageCode: languageCode,
                speed: speed,
                pauseBefore: ParagraphPause.clamped(pauseBefore)
            )
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
        if let replayRecordingID { replayCache.abort(recordingID: replayRecordingID) }
        replayRecordingID = nil
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
        await activityGate?.endSpeech(sessionID: activeID)
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
        let generation = sessionGeneration
        let recordingID = replayRecordingID
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
            do {
                try await waitForParagraphPause(segment.pauseBefore)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            await sink(
                ReadBackServerEvent(
                    type: .speechStarted,
                    sessionID: expectedSessionID,
                    sequence: segment.sequence
                )
            )

            do {
                let request = SpeechRequest(
                    input: segment.text,
                    voice: segment.voice,
                    languageCode: segment.languageCode,
                    speed: segment.speed,
                    format: .wav
                )
                let key = try await synthesizer.replayKey(for: request)
                try Task.checkCancellation()
                guard sessionID == expectedSessionID, sessionGeneration == generation else { return }
                let speech: ReplayableSpeech
                if let key, let cached = replayCache.clip(at: segment.sequence, matching: key) {
                    speech = ReplayableSpeech(clip: cached, key: key)
                } else {
                    speech = try await synthesizer.synthesizeForReplay(request)
                }
                try Task.checkCancellation()
                await waitUntilResumed()
                try Task.checkCancellation()
                guard sessionID == expectedSessionID, sessionGeneration == generation else { return }
                try await player.play(speech.clip)
                try Task.checkCancellation()
                guard sessionID == expectedSessionID, sessionGeneration == generation else { return }
                if let recordingID {
                    if let key = speech.key {
                        replayCache.record(speech.clip, key: key, recordingID: recordingID)
                    } else {
                        replayCache.abort(recordingID: recordingID)
                    }
                }
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
                guard sessionID == expectedSessionID, sessionGeneration == generation else { return }
                if let recordingID { replayCache.abort(recordingID: recordingID) }
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
        if let replayRecordingID { replayCache.complete(recordingID: replayRecordingID) }
        replayRecordingID = nil
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
        await activityGate?.endSpeech(sessionID: id)
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

    private func waitForParagraphPause(_ seconds: Double) async throws {
        var remainingMilliseconds = Int((seconds * 1_000).rounded())
        while remainingMilliseconds > 0 {
            await waitUntilResumed()
            try Task.checkCancellation()
            let slice = min(remainingMilliseconds, 10)
            let clock = ContinuousClock()
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(slice)))
            if !playbackPaused {
                remainingMilliseconds -= slice
            }
        }
    }

    private func resumePauseWaiters() {
        let waiters = pauseWaiters
        pauseWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}
