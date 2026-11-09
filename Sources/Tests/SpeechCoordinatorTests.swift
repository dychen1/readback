import Foundation
import ReadBackCore

func speechCoordinatorTests() -> [TestCase] {
    [
        TestCase(name: "speech coordinator emits an ordered session lifecycle") {
            let synthesizer = RecordingSynthesizer()
            let player = RecordingAudioPlayer()
            let events = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: synthesizer,
                player: player
            )

            try await coordinator.replaceSession(id: "session-1") { event in
                await events.record(event)
            }
            _ = try await coordinator.enqueue(
                sessionID: "session-1",
                text: "Hello",
                voice: "af_heart",
                speed: 1
            )
            await coordinator.finishInput(sessionID: "session-1")
            let outcome = await coordinator.waitUntilFinished(sessionID: "session-1")

            let recordedKinds = await events.kinds()
            let finishedReason = await events.last(.sessionFinished)?.reason
            let synthesizedInputs = await synthesizer.inputs()
            let playCount = await player.playCount()
            try expectEqual(
                recordedKinds,
                [.sessionReady, .speechQueued, .speechStarted, .speechFinished, .sessionFinished],
                "event order"
            )
            try expectEqual(outcome, .completed, "outcome")
            try expectEqual(finishedReason, .completed, "finished reason")
            try expectEqual(synthesizedInputs, ["Hello"], "synthesized text")
            try expectEqual(playCount, 1, "play count")
        },
        TestCase(name: "speech coordinator reports a chunk's range right before its audio plays") {
            let player = StateCapturingAudioPlayer()
            let synthesizer = StateCapturingSynthesizer()
            let coordinator = SpeechCoordinator(synthesizer: synthesizer, player: player)
            await player.attach(coordinator)
            await synthesizer.attach(coordinator)

            try await coordinator.replaceSession(id: "ranges") { _ in }
            _ = try await coordinator.enqueueWaitingForRoom(
                [
                    StreamedTextChunk(text: "One.", endsParagraph: false, sourceRange: 0..<4),
                    StreamedTextChunk(text: "Two.", endsParagraph: false, sourceRange: 5..<9),
                ],
                sessionID: "ranges",
                settings: SpeechSettings(voice: nil, languageCode: nil, synthesisSpeed: 1, paragraphPause: 0),
                pauseBefore: 0
            )
            await coordinator.finishInput(sessionID: "ranges")
            _ = await coordinator.waitUntilFinished(sessionID: "ranges")

            let atSynthesis = await synthesizer.states()
            let atPlay = await player.states()
            let afterEnd = await coordinator.currentPlaybackState
            try expectEqual(
                atSynthesis.map { $0?.chunkRange },
                [nil, 0..<4],
                "synthesis of a chunk does not move the range"
            )
            try expectEqual(atSynthesis.first??.phase, .starting, "no chunk plays during the first synthesis")
            try expectEqual(atPlay.map { $0?.chunkRange }, [0..<4, 5..<9], "range is set before each clip plays")
            try expectEqual(atPlay.map { $0?.phase }, [.playing, .playing], "phase is playing when audio starts")
            try expectEqual(afterEnd, nil, "no state after the reading ends")
        },
        TestCase(name: "speech coordinator playback state follows links, pauses and the end of a reading") {
            let player = PausableAudioPlayer()
            let coordinator = SpeechCoordinator(synthesizer: RecordingSynthesizer(), player: player)
            var updates = await coordinator.playbackUpdates().makeAsyncIterator()
            let initial = await updates.next()
            try expectEqual(initial, .some(nil), "nothing plays at first")

            try await coordinator.replaceSession(id: "first") { _ in }
            let started = await updates.next()
            try expectEqual(started, SpeechPlaybackState(sessionID: "first"), "a new reading starts")
            await coordinator.linkHistoryEntry(7, toSession: "first")
            let linked = await updates.next()
            try expectEqual(
                linked,
                SpeechPlaybackState(sessionID: "first", historyEntryID: 7),
                "the link names the entry"
            )
            await coordinator.linkHistoryEntry(8, toSession: "stale")
            let afterStaleLink = await coordinator.currentPlaybackState?.historyEntryID
            try expectEqual(afterStaleLink, 7, "a stale link changes nothing")

            _ = try await coordinator.enqueue(
                sessionID: "first",
                text: "Hello",
                voice: nil,
                speed: 1,
                sourceRange: 0..<5
            )
            await player.waitUntilPlaying()
            let playing = SpeechPlaybackState(
                sessionID: "first",
                historyEntryID: 7,
                phase: .playing,
                chunkRange: 0..<5
            )
            let chunkStart = await updates.next()
            try expectEqual(chunkStart, playing, "the chunk plays")
            await coordinator.pause(sessionID: "first")
            let pausedPhase = await updates.next()??.phase
            try expectEqual(pausedPhase, .paused, "pause keeps the range")
            let pausedRange = await coordinator.currentPlaybackState?.chunkRange
            try expectEqual(pausedRange, 0..<5, "paused range")
            await coordinator.resume(sessionID: "first")
            let resumed = await updates.next()
            try expectEqual(resumed, playing, "resume plays the same chunk")

            try await coordinator.replaceSession(id: "second") { _ in }
            let replaced = await coordinator.currentPlaybackState
            try expectEqual(replaced, SpeechPlaybackState(sessionID: "second"), "a replacement has no entry or range")
            await coordinator.stop()
            let afterStop = await coordinator.currentPlaybackState
            try expectEqual(afterStop, nil, "stop clears the state")
        },
        TestCase(name: "speech coordinator replacing a session interrupts the current reading") {
            let player = PausableAudioPlayer()
            let gate = ReadBackActivityGate()
            let firstEvents = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player,
                activityGate: gate
            )
            try await coordinator.replaceSession(id: "first") { event in
                await firstEvents.record(event)
            }
            _ = try await coordinator.enqueue(sessionID: "first", text: "Old", voice: nil, speed: 1)
            await coordinator.finishInput(sessionID: "first")
            await player.waitUntilPlaying()
            let firstOutcome = Task { await coordinator.waitUntilFinished(sessionID: "first") }

            try await coordinator.replaceSession(id: "second") { _ in }

            let outcome = await firstOutcome.value
            let reason = await firstEvents.last(.sessionFinished)?.reason
            let stops = await player.stopCount()
            let current = await coordinator.currentSessionID
            let gateState = await gate.currentState()
            try expectEqual(outcome, .interrupted, "replaced reading outcome")
            try expectEqual(reason, .interrupted, "replaced reading is told why it ended")
            try expectEqual(stops, 1, "old audio stops")
            try expectEqual(current, "second", "new reading is current")
            try expectEqual(gateState, .speech(sessionID: "second"), "gate follows the new reading")
            await coordinator.cancel(sessionID: "second")
        },
        TestCase(name: "speech coordinator: a reading stopped while its text queues does not block the next one") {
            let synthesizer = RecordingSynthesizer()
            let coordinator = SpeechCoordinator(
                synthesizer: synthesizer,
                player: RecordingAudioPlayer()
            )
            let hold = SinkHold()
            try await coordinator.replaceSession(id: "old") { event in
                if event.type == .speechQueued { await hold.block() }
            }
            let oldEnqueue = Task {
                try await coordinator.enqueue(sessionID: "old", text: "Old", voice: nil, speed: 1)
            }
            await hold.waitUntilBlocked()
            await coordinator.stop()
            await hold.release()
            let oldResult = await oldEnqueue.result

            try await coordinator.replaceSession(id: "new") { _ in }
            _ = try await coordinator.enqueue(sessionID: "new", text: "New", voice: nil, speed: 1)
            await coordinator.finishInput(sessionID: "new")
            // Before the fix the new reading never started; stop it so the test fails
            // instead of hanging.
            let watchdog = Task {
                try await wait(for: .seconds(2))
                await coordinator.stop()
            }
            let outcome = await coordinator.waitUntilFinished(sessionID: "new")
            watchdog.cancel()

            let inputs = await synthesizer.inputs()
            try expectEqual(outcome, .completed, "the next reading plays to the end")
            try expectEqual(inputs, ["New"], "only the next reading is synthesized")
            if case .success = oldResult {
                throw TestFailure(description: "the stopped reading's enqueue must report sessionNotActive")
            }
        },
        TestCase(name: "speech coordinator ignores operations from a replaced session") {
            let player = PausableAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player
            )
            try await coordinator.replaceSession(id: "stale") { _ in }
            try await coordinator.replaceSession(id: "current") { _ in }
            _ = try await coordinator.enqueue(sessionID: "current", text: "Keep", voice: nil, speed: 1)
            await player.waitUntilPlaying()

            do {
                _ = try await coordinator.enqueue(sessionID: "stale", text: "Late", voice: nil, speed: 1)
                throw TestFailure(description: "late text from a replaced session must be rejected")
            } catch let error as SpeechCoordinatorError {
                try expectEqual(error, .sessionNotActive, "stale enqueue error")
            }
            await coordinator.finishInput(sessionID: "stale")
            await coordinator.pause(sessionID: "stale")
            await coordinator.cancel(sessionID: "stale")

            let current = await coordinator.currentSessionID
            let paused = await coordinator.isPaused
            let pauses = await player.pauseCount()
            try expectEqual(current, "current", "stale cancel keeps the newer reading")
            try expect(!paused, "stale pause is ignored")
            try expectEqual(pauses, 0, "stale pause never reaches the player")
            await coordinator.cancel(sessionID: "current")
        },
        TestCase(name: "speech coordinator replacing a paused reading releases its worker") {
            let player = PausableAudioPlayer()
            let synthesizer = RecordingSynthesizer()
            let coordinator = SpeechCoordinator(synthesizer: synthesizer, player: player)
            try await coordinator.replaceSession(id: "paused") { _ in }
            _ = try await coordinator.enqueue(sessionID: "paused", text: "One", voice: nil, speed: 1)
            _ = try await coordinator.enqueue(sessionID: "paused", text: "Two", voice: nil, speed: 1)
            await player.waitUntilPlaying()
            await coordinator.pause(sessionID: "paused")

            try await coordinator.replaceSession(id: "next") { _ in }
            _ = try await coordinator.enqueue(sessionID: "next", text: "Next", voice: nil, speed: 1)
            await coordinator.finishInput(sessionID: "next")
            let finished = Task { await coordinator.waitUntilFinished(sessionID: "next") }
            while await player.playCount() < 2 {
                try await wait(for: .milliseconds(2))
            }
            await player.finishCurrent()

            let outcome = await finished.value
            let inputs = await synthesizer.inputs()
            try expectEqual(outcome, .completed, "new reading completes")
            try expectEqual(inputs, ["One", "Next"], "paused text never resumes")
        },
        TestCase(name: "speech coordinator rejects a new reading during a model switch") {
            let gate = ReadBackActivityGate()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: RecordingAudioPlayer(),
                activityGate: gate
            )
            try await gate.beginModelSwitch()

            do {
                try await coordinator.replaceSession(id: "during-switch") { _ in }
                throw TestFailure(description: "replace must fail during a model switch")
            } catch let error as SpeechCoordinatorError {
                try expectEqual(error, .modelSwitchInProgress, "switch error")
            }
            let active = await coordinator.hasActiveSession
            let gateState = await gate.currentState()
            try expect(!active, "no session starts")
            try expectEqual(gateState, .modelSwitch, "model switch keeps the gate")
        },
        TestCase(name: "speech coordinator keeps the gate with the current session under concurrent replacements") {
            let gate = ReadBackActivityGate()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: RecordingAudioPlayer(),
                activityGate: gate
            )
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask {
                        try? await coordinator.replaceSession(id: "reading-\(index)") { _ in }
                    }
                }
            }

            let current = await coordinator.currentSessionID
            let gateState = await gate.currentState()
            try expect(current != nil, "one reading is current")
            try expectEqual(gateState, .speech(sessionID: current!), "gate owner matches current reading")

            let stopped = await coordinator.stop()
            let releasedState = await gate.currentState()
            try expect(stopped, "stop ends the current reading")
            try expectEqual(releasedState, .idle, "gate is released")
        },
        TestCase(name: "speech coordinator stop ends any reading and reports whether one was playing") {
            let gate = ReadBackActivityGate()
            let events = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: BlockingSynthesizer(),
                player: RecordingAudioPlayer(),
                activityGate: gate
            )
            let stoppedNothing = await coordinator.stop()
            try expect(!stoppedNothing, "stop with nothing playing")

            try await coordinator.replaceSession(id: "any-source") { event in
                await events.record(event)
            }
            _ = try await coordinator.enqueue(sessionID: "any-source", text: "Stop me", voice: nil, speed: 1)
            let stopped = await coordinator.stop()

            let outcome = await coordinator.waitUntilFinished(sessionID: "any-source")
            let reason = await events.last(.sessionFinished)?.reason
            let gateState = await gate.currentState()
            try expect(stopped, "stop reports the ended reading")
            try expectEqual(outcome, .stopped, "stopped outcome")
            try expectEqual(reason, .stopped, "stopped reason")
            try expectEqual(gateState, .idle, "gate released after stop")
        },
        TestCase(name: "speech coordinator reports a synthesis failure as a failed outcome") {
            let events = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: FailingSynthesizer(),
                player: RecordingAudioPlayer()
            )
            try await coordinator.replaceSession(id: "failing") { event in
                await events.record(event)
            }
            _ = try await coordinator.enqueue(sessionID: "failing", text: "Broken", voice: nil, speed: 1)
            await coordinator.finishInput(sessionID: "failing")

            let outcome = await coordinator.waitUntilFinished(sessionID: "failing")
            let finished = await events.last(.sessionFinished)
            guard case .failed(let message) = outcome else {
                throw TestFailure(description: "expected a failed outcome, got \(outcome)")
            }
            try expect(message.contains("synthesis exploded"), "failure message is kept")
            try expectEqual(finished?.reason, .failed, "failed reason")
        },
        TestCase(name: "speech coordinator publishes reading activity") {
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: RecordingAudioPlayer()
            )
            var updates = await coordinator.activityUpdates().makeAsyncIterator()
            let initial = await updates.next()
            try await coordinator.replaceSession(id: "observed") { _ in }
            let started = await updates.next()
            await coordinator.cancel(sessionID: "observed")
            let ended = await updates.next()

            try expectEqual(initial, false, "idle at first")
            try expectEqual(started, true, "active while reading")
            try expectEqual(ended, false, "idle after the reading ends")
        },
        TestCase(name: "speech coordinator enforces pending character limit") {
            let synthesizer = BlockingSynthesizer()
            let events = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: synthesizer,
                player: RecordingAudioPlayer(),
                maximumPendingCharacters: 2_000
            )
            try await coordinator.replaceSession(id: "limited") { event in
                await events.record(event)
            }
            _ = try await coordinator.enqueue(
                sessionID: "limited",
                text: String(repeating: "a", count: 1_500),
                voice: "af_heart",
                speed: 1
            )
            await synthesizer.waitUntilStarted()

            do {
                _ = try await coordinator.enqueue(
                    sessionID: "limited",
                    text: String(repeating: "b", count: 501),
                    voice: "af_heart",
                    speed: 1
                )
                throw TestFailure(description: "queue overflow should fail")
            } catch let error as SpeechCoordinatorError {
                try expectEqual(error, .queueLimitExceeded, "queue limit error")
            }
            let recordedKinds = await events.kinds()
            try expect(recordedKinds.contains(.queuePaused), "pause event")
            await coordinator.cancel(sessionID: "limited")
            await synthesizer.release()
        },
        TestCase(name: "speech coordinator queues text beyond the pending limit by waiting for room") {
            let synthesizer = RecordingSynthesizer()
            let coordinator = SpeechCoordinator(
                synthesizer: synthesizer,
                player: RecordingAudioPlayer(),
                maximumPendingCharacters: 12
            )
            try await coordinator.replaceSession(id: "long") { _ in }
            let chunks = (1...5).map { StreamedTextChunk(text: "Chunk \($0).", endsParagraph: false) }
            let settings = SpeechSettings(voice: nil, languageCode: nil, synthesisSpeed: 1, paragraphPause: 0)

            _ = try await coordinator.enqueueWaitingForRoom(
                chunks,
                sessionID: "long",
                settings: settings,
                pauseBefore: 0
            )
            await coordinator.finishInput(sessionID: "long")
            let outcome = await coordinator.waitUntilFinished(sessionID: "long")

            let inputs = await synthesizer.inputs()
            try expectEqual(outcome, .completed, "long reading completes")
            try expectEqual(inputs, chunks.map(\.text), "all chunks in order")
        },
        TestCase(name: "speech coordinator rejects a chunk that can never fit instead of waiting") {
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: RecordingAudioPlayer(),
                maximumPendingCharacters: 12
            )
            try await coordinator.replaceSession(id: "oversized") { _ in }
            let settings = SpeechSettings(voice: nil, languageCode: nil, synthesisSpeed: 1, paragraphPause: 0)

            do {
                _ = try await coordinator.enqueueWaitingForRoom(
                    [StreamedTextChunk(text: "This chunk is longer than twelve.", endsParagraph: false)],
                    sessionID: "oversized",
                    settings: settings,
                    pauseBefore: 0
                )
                throw TestFailure(description: "an oversized chunk must be rejected")
            } catch SpeechCoordinatorError.queueLimitExceeded {}
            await coordinator.cancel(sessionID: "oversized")
        },
        TestCase(name: "speech coordinator cancellation stops playback") {
            let player = RecordingAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: BlockingSynthesizer(),
                player: player
            )
            try await coordinator.replaceSession(id: "cancelled") { _ in }
            _ = try await coordinator.enqueue(sessionID: "cancelled", text: "Cancel me", voice: "af_heart", speed: 1)

            await coordinator.cancel(sessionID: "cancelled")

            let stopCount = await player.stopCount()
            let hasActiveSession = await coordinator.hasActiveSession
            let outcome = await coordinator.waitUntilFinished(sessionID: "cancelled")
            try expectEqual(stopCount, 1, "stop count")
            try expect(!hasActiveSession, "session should be cleared")
            try expectEqual(outcome, .stopped, "cancelled outcome")
        },
        TestCase(name: "speech coordinator pauses and resumes the active audio player") {
            let player = PausableAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player
            )
            try await coordinator.replaceSession(id: "pausable") { _ in }
            _ = try await coordinator.enqueue(sessionID: "pausable", text: "Pause me", voice: "af_heart", speed: 1)
            await coordinator.finishInput(sessionID: "pausable")
            await player.waitUntilPlaying()

            await coordinator.pause(sessionID: "pausable")
            let pauseCount = await player.pauseCount()
            let paused = await coordinator.isPaused
            try expectEqual(pauseCount, 1, "pause count")
            try expect(paused, "coordinator paused state")

            await coordinator.resume(sessionID: "pausable")
            await coordinator.waitUntilFinished(sessionID: "pausable")
            let resumeCount = await player.resumeCount()
            let resumed = await coordinator.isPaused
            try expectEqual(resumeCount, 1, "resume count")
            try expect(!resumed, "coordinator resumed state")
        },
        TestCase(name: "speech coordinator does not acknowledge a pause after cancellation") {
            let player = SuspendingControlAudioPlayer()
            let events = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player
            )
            try await coordinator.replaceSession(id: "old-session") { event in
                await events.record(event)
            }

            let pause = Task { await coordinator.pause(sessionID: "old-session") }
            await player.waitUntilPauseStarted()
            await coordinator.cancel(sessionID: "old-session")
            await player.releasePause()
            await pause.value

            let recordedKinds = await events.kinds()
            try expect(
                !recordedKinds.contains(.playbackPaused),
                "cancelled session must not emit a late pause acknowledgment"
            )
        },
        TestCase(name: "speech coordinator never runs two synthesis calls at once") {
            let synthesizer = RecordingSynthesizer(delayNanoseconds: 2_000_000)
            let coordinator = SpeechCoordinator(
                synthesizer: synthesizer,
                player: RecordingAudioPlayer()
            )
            try await coordinator.replaceSession(id: "serial") { _ in }
            for text in ["One", "Two", "Three"] {
                _ = try await coordinator.enqueue(sessionID: "serial", text: text, voice: "af_heart", speed: 1)
            }
            await coordinator.finishInput(sessionID: "serial")
            await coordinator.waitUntilFinished(sessionID: "serial")

            let maximumConcurrentCalls = await synthesizer.maximumConcurrentCalls()
            try expectEqual(maximumConcurrentCalls, 1, "synthesis concurrency")
        },
        TestCase(name: "speech coordinator waits between paragraph segments") {
            let player = TimestampAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player
            )
            try await coordinator.replaceSession(id: "paragraph-gap") { _ in }
            _ = try await coordinator.enqueue(
                sessionID: "paragraph-gap",
                text: "First paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1
            )
            _ = try await coordinator.enqueue(
                sessionID: "paragraph-gap",
                text: "Second paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1,
                pauseBefore: 0.08
            )
            await coordinator.finishInput(sessionID: "paragraph-gap")
            await coordinator.waitUntilFinished(sessionID: "paragraph-gap")

            let intervals = await player.playIntervals()
            try expectEqual(intervals.count, 1, "paragraph play interval count")
            try expect(intervals[0] >= 0.07, "paragraph gap must delay the next clip")
        },
        TestCase(name: "speech coordinator pauses and resumes a paragraph gap") {
            let player = ParagraphGapAudioPlayer()
            let clock = ContinuousClock()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player
            )
            try await coordinator.replaceSession(id: "paused-gap") { _ in }
            _ = try await coordinator.enqueue(
                sessionID: "paused-gap",
                text: "First paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1
            )
            _ = try await coordinator.enqueue(
                sessionID: "paused-gap",
                text: "Second paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1,
                pauseBefore: 0.08
            )
            await coordinator.finishInput(sessionID: "paused-gap")
            await player.waitForFirstPlay()
            try await wait(for: .milliseconds(20))

            await coordinator.pause(sessionID: "paused-gap")
            try await wait(for: .milliseconds(120))
            let pausedPlayCount = await player.playCount()
            try expectEqual(pausedPlayCount, 1, "paused paragraph gap play count")

            let resumedAt = clock.now
            await coordinator.resume(sessionID: "paused-gap")
            await coordinator.waitUntilFinished(sessionID: "paused-gap")
            let resumedPlayCount = await player.playCount()
            let secondPlayAt = await player.lastPlayTime()
            try expectEqual(resumedPlayCount, 2, "resumed paragraph gap play count")
            let resumedDelay = resumedAt.duration(to: secondPlayAt).components
            let resumedDelaySeconds = Double(resumedDelay.seconds)
                + Double(resumedDelay.attoseconds) / 1_000_000_000_000_000_000
            try expect(
                resumedDelaySeconds >= 0.04,
                "resume must preserve the unused paragraph gap"
            )
        },
    ]
}

/// Blocks a session's event sink until released, to hold a call inside `enqueue`.
private actor SinkHold {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor EventRecorder {
    private var events: [ReadBackServerEvent] = []

    func record(_ event: ReadBackServerEvent) {
        events.append(event)
    }

    func kinds() -> [ReadBackServerEvent.Kind] {
        events.map(\.type)
    }

    func last(_ kind: ReadBackServerEvent.Kind) -> ReadBackServerEvent? {
        events.last { $0.type == kind }
    }
}

private actor RecordingSynthesizer: SpeechSynthesizing {
    private let delayNanoseconds: UInt64
    private var recordedInputs: [String] = []
    private var concurrentCalls = 0
    private var maximumConcurrency = 0

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        recordedInputs.append(request.input)
        concurrentCalls += 1
        maximumConcurrency = max(maximumConcurrency, concurrentCalls)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        concurrentCalls -= 1
        return AudioClip(data: Data(request.input.utf8), format: .wav)
    }

    func inputs() -> [String] {
        recordedInputs
    }

    func maximumConcurrentCalls() -> Int {
        maximumConcurrency
    }
}

private struct FailingSynthesizer: SpeechSynthesizing {
    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        throw TestFailure(description: "synthesis exploded")
    }
}

private actor TimestampAudioPlayer: AudioPlaying {
    private let clock = ContinuousClock()
    private var playTimes: [ContinuousClock.Instant] = []

    func play(_ clip: AudioClip) async throws {
        playTimes.append(clock.now)
    }

    func stop() async {}
    func pause() async {}
    func resume() async {}

    func playIntervals() -> [Double] {
        zip(playTimes, playTimes.dropFirst()).map { start, end in
            let duration = start.duration(to: end)
            return Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        }
    }
}

private actor ParagraphGapAudioPlayer: AudioPlaying {
    private var plays = 0
    private let clock = ContinuousClock()
    private var playTimes: [ContinuousClock.Instant] = []
    private var firstPlayWaiters: [CheckedContinuation<Void, Never>] = []

    func play(_ clip: AudioClip) async throws {
        plays += 1
        playTimes.append(clock.now)
        if plays == 1 {
            firstPlayWaiters.forEach { $0.resume() }
            firstPlayWaiters.removeAll()
        }
    }

    func stop() async {}
    func pause() async {}
    func resume() async {}

    func waitForFirstPlay() async {
        if plays > 0 { return }
        await withCheckedContinuation { firstPlayWaiters.append($0) }
    }

    func playCount() -> Int { plays }
    func lastPlayTime() -> ContinuousClock.Instant { playTimes.last! }
}

private actor BlockingSynthesizer: SpeechSynthesizing {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        try Task.checkCancellation()
        return AudioClip(data: Data(request.input.utf8), format: .wav)
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RecordingAudioPlayer: AudioPlaying {
    private var plays = 0
    private var stops = 0

    func play(_ clip: AudioClip) async throws {
        plays += 1
    }

    func stop() async {
        stops += 1
    }

    func pause() async {}

    func resume() async {}

    func playCount() -> Int {
        plays
    }

    func stopCount() -> Int {
        stops
    }
}

/// Holds each clip until it is stopped, resumed, or explicitly finished.
private actor PausableAudioPlayer: AudioPlaying {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?
    private var pauses = 0
    private var resumes = 0
    private var stops = 0
    private var plays = 0

    func play(_ clip: AudioClip) async throws {
        plays += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { completion = $0 }
    }

    func stop() async {
        stops += 1
        finishCurrent()
    }

    func pause() async {
        pauses += 1
    }

    func resume() async {
        resumes += 1
        finishCurrent()
    }

    func finishCurrent() {
        completion?.resume()
        completion = nil
    }

    func waitUntilPlaying() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func pauseCount() -> Int { pauses }
    func resumeCount() -> Int { resumes }
    func stopCount() -> Int { stops }
    func playCount() -> Int { plays }
}

private actor SuspendingControlAudioPlayer: AudioPlaying {
    private var pauseStarted = false
    private var pauseStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseRelease: CheckedContinuation<Void, Never>?

    func play(_ clip: AudioClip) async throws {}
    func stop() async {}

    func pause() async {
        pauseStarted = true
        pauseStartWaiters.forEach { $0.resume() }
        pauseStartWaiters.removeAll()
        await withCheckedContinuation { pauseRelease = $0 }
    }

    func resume() async {}

    func waitUntilPauseStarted() async {
        if pauseStarted { return }
        await withCheckedContinuation { pauseStartWaiters.append($0) }
    }

    func releasePause() {
        pauseRelease?.resume()
        pauseRelease = nil
    }
}

/// Records the coordinator's playback state at the moment each clip starts to play.
private actor StateCapturingAudioPlayer: AudioPlaying {
    private var coordinator: SpeechCoordinator?
    private var captured: [SpeechPlaybackState?] = []

    func attach(_ coordinator: SpeechCoordinator) {
        self.coordinator = coordinator
    }

    func play(_ clip: AudioClip) async throws {
        captured.append(await coordinator?.currentPlaybackState)
    }

    func stop() async {}
    func pause() async {}
    func resume() async {}

    func states() -> [SpeechPlaybackState?] { captured }
}

/// Records the coordinator's playback state at the moment each chunk starts to synthesize.
private actor StateCapturingSynthesizer: SpeechSynthesizing {
    private var coordinator: SpeechCoordinator?
    private var captured: [SpeechPlaybackState?] = []

    func attach(_ coordinator: SpeechCoordinator) {
        self.coordinator = coordinator
    }

    func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        captured.append(await coordinator?.currentPlaybackState)
        return AudioClip(data: Data(request.input.utf8), format: .wav)
    }

    func states() -> [SpeechPlaybackState?] { captured }
}
