import Foundation

public protocol AudioPlaying: Sendable {
    func play(_ clip: AudioClip) async throws
    func stop() async
    func pause() async
    func resume() async
}

public enum SpeechCoordinatorError: Error, Equatable, Sendable {
    /// The session ended or a newer reading replaced it.
    case sessionNotActive
    case modelSwitchInProgress
    case queueLimitExceeded
}

/// How a reading ended.
public enum SpeechSessionOutcome: Equatable, Sendable {
    case completed
    /// A newer reading replaced it.
    case interrupted
    /// Its own client cancelled it, or the app's Stop control ended it.
    case stopped
    /// Every segment was attempted, but at least one failed to synthesize or play.
    case failed(String)

    var endReason: ReadBackServerEvent.EndReason {
        switch self {
        case .completed: .completed
        case .interrupted: .interrupted
        case .stopped: .stopped
        case .failed: .failed
        }
    }
}

/// Owns the single current reading. Every operation that targets a reading names its
/// session, so a client whose reading was replaced cannot affect the newer one.
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

    private struct EndedSession: Sendable {
        let id: String
        let sink: EventSink
        let outcome: SpeechSessionOutcome
    }

    private static let recentOutcomeLimit = 16

    private let synthesizer: any SpeechSynthesizing
    private let player: any AudioPlaying
    private let activityGate: ReadBackActivityGate?
    private let maximumPendingCharacters: Int

    private var sessionID: String?
    private var sessionGeneration = 0
    private var eventSink: EventSink?
    private var sessionFailure: String?
    private var queue: [Segment] = []
    private var nextSequence = 0
    private var pendingCharacters = 0
    private var inputFinished = false
    private var queuePaused = false
    private var playbackPaused = false
    private var worker: Task<Void, Never>?
    private var completionWaiters: [String: [CheckedContinuation<SpeechSessionOutcome, Never>]] = [:]
    private var recentOutcomes: [(id: String, outcome: SpeechSessionOutcome)] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var transitionTail: Task<Void, Never>?
    private var activityContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
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

    public var currentSessionID: String? {
        sessionID
    }

    public var isPaused: Bool {
        playbackPaused
    }

    /// Yields whether a reading is active, starting with the current state.
    public func activityUpdates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        activityContinuations[id] = continuation
        continuation.yield(sessionID != nil)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivityContinuation(id) }
        }
        return stream
    }

    /// Makes `id` the current reading. A reading already in progress, whatever started
    /// it, ends as `.interrupted` and its audio stops before the new session starts.
    /// Throws `.modelSwitchInProgress`, and leaves everything unchanged, while a model
    /// switch holds the activity gate.
    public func replaceSession(id: String, events: @escaping EventSink) async throws {
        try await serialized { try await self.performReplace(id: id, events: events) }
    }

    /// Ends the current reading, whatever started it. Returns `false` when nothing was
    /// playing.
    @discardableResult
    public func stop() async -> Bool {
        (try? await serialized { await self.performEnd(sessionID: nil) }) ?? false
    }

    /// Ends `sessionID` as `.stopped` if it is still the current reading.
    public func cancel(sessionID: String) async {
        _ = try? await serialized { await self.performEnd(sessionID: sessionID) }
    }

    /// Drops saved and pending replay data without stopping active playback.
    public func invalidateReplayCache() {
        replayCache.invalidate()
    }

    @discardableResult
    public func enqueue(
        sessionID expectedSessionID: String,
        text: String,
        voice: String?,
        languageCode: String? = nil,
        speed: Double,
        pauseBefore: Double = 0
    ) async throws -> Int {
        guard sessionID == expectedSessionID, let eventSink else {
            throw SpeechCoordinatorError.sessionNotActive
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nextSequence
        }
        guard pendingCharacters + normalized.count <= maximumPendingCharacters else {
            if !queuePaused {
                queuePaused = true
                await eventSink(
                    ReadBackServerEvent(type: .queuePaused, sessionID: expectedSessionID)
                )
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
            ReadBackServerEvent(type: .speechQueued, sessionID: expectedSessionID, sequence: sequence)
        )
        startWorkerIfNeeded(sessionID: expectedSessionID)
        return sequence
    }

    /// Queues `chunks` in order, waiting while the pending-text limit is reached.
    /// Returns the pause to put before the next chunk. Throws `.sessionNotActive` as
    /// soon as the session ends.
    public func enqueueWaitingForRoom(
        _ chunks: [StreamedTextChunk],
        sessionID expectedSessionID: String,
        settings: SpeechSettings,
        pauseBefore: Double
    ) async throws -> Double {
        var nextPause = pauseBefore
        for chunk in chunks {
            while true {
                do {
                    try await enqueue(
                        sessionID: expectedSessionID,
                        text: chunk.text,
                        voice: settings.voice,
                        languageCode: settings.languageCode,
                        speed: settings.synthesisSpeed,
                        pauseBefore: nextPause
                    )
                    nextPause = chunk.endsParagraph ? settings.paragraphPause : 0
                    break
                } catch SpeechCoordinatorError.queueLimitExceeded {
                    let clock = ContinuousClock()
                    try await clock.sleep(until: clock.now.advanced(by: .milliseconds(25)))
                }
            }
        }
        return nextPause
    }

    public func finishInput(sessionID expectedSessionID: String) async {
        guard sessionID == expectedSessionID else {
            return
        }
        inputFinished = true
        if queue.isEmpty, worker == nil {
            await completeSession(id: expectedSessionID)
        }
    }

    /// Waits for `sessionID` to end and reports how it ended. Pass only an ID that
    /// `replaceSession` accepted; one that ended too long ago to be remembered can
    /// only have been replaced, so it reports `.interrupted`.
    @discardableResult
    public func waitUntilFinished(sessionID expectedSessionID: String) async -> SpeechSessionOutcome {
        if let recent = recentOutcomes.last(where: { $0.id == expectedSessionID }) {
            return recent.outcome
        }
        guard sessionID == expectedSessionID else {
            return .interrupted
        }
        return await withCheckedContinuation { continuation in
            completionWaiters[expectedSessionID, default: []].append(continuation)
        }
    }

    public func pause(sessionID expectedSessionID: String) async {
        guard sessionID == expectedSessionID, let eventSink, !playbackPaused else { return }
        let generation = sessionGeneration
        playbackPaused = true
        await player.pause()
        guard sessionID == expectedSessionID,
              sessionGeneration == generation,
              playbackPaused
        else { return }
        await eventSink(ReadBackServerEvent(type: .playbackPaused, sessionID: expectedSessionID))
    }

    public func resume(sessionID expectedSessionID: String) async {
        guard sessionID == expectedSessionID, let eventSink, playbackPaused else { return }
        let generation = sessionGeneration
        playbackPaused = false
        await player.resume()
        guard sessionID == expectedSessionID,
              sessionGeneration == generation,
              !playbackPaused
        else { return }
        resumePauseWaiters()
        await eventSink(ReadBackServerEvent(type: .playbackResumed, sessionID: expectedSessionID))
    }

    // MARK: - Session transitions

    /// Runs session transitions one at a time. Each one awaits the gate, the player,
    /// and event sinks, so without this two transitions could interleave and leave
    /// the gate owned by a session that is no longer current.
    private func serialized<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let previous = transitionTail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        transitionTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func performReplace(id: String, events: @escaping EventSink) async throws {
        do {
            try await activityGate?.claimSpeech(sessionID: id)
        } catch {
            throw SpeechCoordinatorError.modelSwitchInProgress
        }
        if let previous = endCurrentSession(outcome: .interrupted) {
            await player.stop()
            await previous.sink(Self.finishedEvent(for: previous))
        }

        sessionID = id
        sessionGeneration += 1
        eventSink = events
        sessionFailure = nil
        queue.removeAll(keepingCapacity: true)
        nextSequence = 0
        pendingCharacters = 0
        inputFinished = false
        queuePaused = false
        playbackPaused = false
        replayRecordingID = replayCache.beginRecording()
        publishActivity()
        await events(ReadBackServerEvent(type: .sessionReady, sessionID: id))
    }

    private func performEnd(sessionID expectedSessionID: String?) async -> Bool {
        guard let ended = endCurrentSession(matching: expectedSessionID, outcome: .stopped) else {
            return false
        }
        await player.stop()
        await ended.sink(Self.finishedEvent(for: ended))
        await activityGate?.endSpeech(sessionID: ended.id)
        return true
    }

    private func completeSession(id: String) async {
        let outcome = sessionFailure.map(SpeechSessionOutcome.failed) ?? .completed
        guard let ended = endCurrentSession(matching: id, outcome: outcome) else { return }
        await ended.sink(Self.finishedEvent(for: ended))
        await activityGate?.endSpeech(sessionID: id)
    }

    /// Clears the current session without suspending, so no other call can observe a
    /// half-ended session. The caller performs the side effects afterwards.
    private func endCurrentSession(
        matching expectedSessionID: String? = nil,
        outcome: SpeechSessionOutcome
    ) -> EndedSession? {
        guard let id = sessionID,
              let sink = eventSink,
              expectedSessionID == nil || expectedSessionID == id
        else { return nil }

        if let replayRecordingID {
            if outcome == .completed {
                replayCache.complete(recordingID: replayRecordingID)
            } else {
                replayCache.abort(recordingID: replayRecordingID)
            }
        }
        replayRecordingID = nil
        sessionGeneration += 1
        worker?.cancel()
        worker = nil
        queue.removeAll(keepingCapacity: true)
        pendingCharacters = 0
        inputFinished = true
        queuePaused = false
        playbackPaused = false
        resumePauseWaiters()
        sessionID = nil
        eventSink = nil
        sessionFailure = nil
        record(outcome, for: id)
        publishActivity()
        return EndedSession(id: id, sink: sink, outcome: outcome)
    }

    private func record(_ outcome: SpeechSessionOutcome, for id: String) {
        recentOutcomes.append((id, outcome))
        if recentOutcomes.count > Self.recentOutcomeLimit {
            recentOutcomes.removeFirst(recentOutcomes.count - Self.recentOutcomeLimit)
        }
        let waiters = completionWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private static func finishedEvent(for session: EndedSession) -> ReadBackServerEvent {
        var message: String?
        if case .failed(let failure) = session.outcome {
            message = failure
        }
        return ReadBackServerEvent(
            type: .sessionFinished,
            sessionID: session.id,
            message: message,
            reason: session.outcome.endReason
        )
    }

    private func publishActivity() {
        let isActive = sessionID != nil
        activityContinuations.values.forEach { $0.yield(isActive) }
    }

    private func removeActivityContinuation(_ id: UUID) {
        activityContinuations[id] = nil
    }

    // MARK: - Playback worker

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
                let message = String(describing: error)
                sessionFailure = sessionFailure ?? message
                await sink(
                    ReadBackServerEvent(
                        type: .error,
                        sessionID: expectedSessionID,
                        sequence: segment.sequence,
                        message: message
                    )
                )
            }
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
