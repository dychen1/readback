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
                player: player,
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )

            try await coordinator.startSession(id: "session-1") { event in
                await events.record(event)
            }
            _ = try await coordinator.enqueue(text: "Hello", voice: "af_heart", speed: 1)
            await coordinator.finishInput()
            await coordinator.waitUntilFinished(sessionID: "session-1")

            let recordedKinds = await events.kinds()
            let synthesizedInputs = await synthesizer.inputs()
            let playCount = await player.playCount()
            try expectEqual(
                recordedKinds,
                [.sessionReady, .speechQueued, .speechStarted, .speechFinished, .sessionFinished],
                "event order"
            )
            try expectEqual(synthesizedInputs, ["Hello"], "synthesized text")
            try expectEqual(playCount, 1, "play count")
        },
        TestCase(name: "speech coordinator allows only one active session") {
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: RecordingAudioPlayer(),
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "first") { _ in }

            do {
                try await coordinator.startSession(id: "second") { _ in }
                throw TestFailure(description: "second session should fail")
            } catch let error as SpeechCoordinatorError {
                try expectEqual(error, .sessionAlreadyActive, "second session error")
            }
            await coordinator.cancel()
        },
        TestCase(name: "speech coordinator enforces pending character limit") {
            let synthesizer = BlockingSynthesizer()
            let events = EventRecorder()
            let coordinator = SpeechCoordinator(
                synthesizer: synthesizer,
                player: RecordingAudioPlayer(),
                modelPath: URL(fileURLWithPath: "/tmp/model"),
                maximumPendingCharacters: 2_000
            )
            try await coordinator.startSession(id: "limited") { event in
                await events.record(event)
            }
            _ = try await coordinator.enqueue(
                text: String(repeating: "a", count: 1_500),
                voice: "af_heart",
                speed: 1
            )
            await synthesizer.waitUntilStarted()

            do {
                _ = try await coordinator.enqueue(
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
            await coordinator.cancel()
            await synthesizer.release()
        },
        TestCase(name: "speech coordinator cancellation stops playback") {
            let player = RecordingAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: BlockingSynthesizer(),
                player: player,
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "cancelled") { _ in }
            _ = try await coordinator.enqueue(text: "Cancel me", voice: "af_heart", speed: 1)

            await coordinator.cancel()

            let stopCount = await player.stopCount()
            let hasActiveSession = await coordinator.hasActiveSession
            try expectEqual(stopCount, 1, "stop count")
            try expect(!hasActiveSession, "session should be cleared")
        },
        TestCase(name: "speech coordinator pauses and resumes the active audio player") {
            let player = PausableAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player,
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "pausable") { _ in }
            _ = try await coordinator.enqueue(text: "Pause me", voice: "af_heart", speed: 1)
            await coordinator.finishInput()
            await player.waitUntilPlaying()

            await coordinator.pause()
            let pauseCount = await player.pauseCount()
            let paused = await coordinator.isPaused
            try expectEqual(pauseCount, 1, "pause count")
            try expect(paused, "coordinator paused state")

            await coordinator.resume()
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
                player: player,
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "old-session") { event in
                await events.record(event)
            }

            let pause = Task { await coordinator.pause() }
            await player.waitUntilPauseStarted()
            await coordinator.cancel()
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
                player: RecordingAudioPlayer(),
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "serial") { _ in }
            for text in ["One", "Two", "Three"] {
                _ = try await coordinator.enqueue(text: text, voice: "af_heart", speed: 1)
            }
            await coordinator.finishInput()
            await coordinator.waitUntilFinished(sessionID: "serial")

            let maximumConcurrentCalls = await synthesizer.maximumConcurrentCalls()
            try expectEqual(maximumConcurrentCalls, 1, "synthesis concurrency")
        },
        TestCase(name: "speech coordinator waits between paragraph segments") {
            let player = TimestampAudioPlayer()
            let coordinator = SpeechCoordinator(
                synthesizer: RecordingSynthesizer(),
                player: player,
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "paragraph-gap") { _ in }
            _ = try await coordinator.enqueue(
                text: "First paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1
            )
            _ = try await coordinator.enqueue(
                text: "Second paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1,
                pauseBefore: 0.08
            )
            await coordinator.finishInput()
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
                player: player,
                modelPath: URL(fileURLWithPath: "/tmp/model")
            )
            try await coordinator.startSession(id: "paused-gap") { _ in }
            _ = try await coordinator.enqueue(
                text: "First paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1
            )
            _ = try await coordinator.enqueue(
                text: "Second paragraph",
                voice: "af_heart",
                languageCode: "a",
                speed: 1,
                pauseBefore: 0.08
            )
            await coordinator.finishInput()
            await player.waitForFirstPlay()
            try await Task.sleep(for: .milliseconds(20))

            await coordinator.pause()
            try await Task.sleep(for: .milliseconds(120))
            let pausedPlayCount = await player.playCount()
            try expectEqual(pausedPlayCount, 1, "paused paragraph gap play count")

            let resumedAt = clock.now
            await coordinator.resume()
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

private actor EventRecorder {
    private var events: [ReadBackServerEvent] = []

    func record(_ event: ReadBackServerEvent) {
        events.append(event)
    }

    func kinds() -> [ReadBackServerEvent.Kind] {
        events.map(\.type)
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

    func synthesize(_ request: SpeechRequest, modelPath: URL) async throws -> AudioClip {
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

    func synthesize(_ request: SpeechRequest, modelPath: URL) async throws -> AudioClip {
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

private actor PausableAudioPlayer: AudioPlaying {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?
    private var pauses = 0
    private var resumes = 0

    func play(_ clip: AudioClip) async throws {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { completion = $0 }
    }

    func stop() async {
        completion?.resume()
        completion = nil
    }

    func pause() async {
        pauses += 1
    }

    func resume() async {
        resumes += 1
        completion?.resume()
        completion = nil
    }

    func waitUntilPlaying() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func pauseCount() -> Int { pauses }
    func resumeCount() -> Int { resumes }
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
