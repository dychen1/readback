import Foundation
import ReadBackCore

private func replayKey(_ text: String, voice: String = "af_heart", generation: UInt64 = 1) -> SpeechReplayKey {
    SpeechReplayKey(modelID: .kokoro, modelGeneration: generation, request: SpeechRequest(
        input: text, voice: voice, languageCode: "a", speed: 1, format: .wav
    ))
}

func speechReplayCacheTests() -> [TestCase] {
    [
        TestCase(name: "replay cache keeps every chunk of only the last completed reading") {
            var cache = SpeechReplayCache()
            let clip = AudioClip(data: Data([1, 2]), format: .wav)
            let first = cache.beginRecording()
            cache.record(clip, key: replayKey("one"), recordingID: first)
            cache.record(clip, key: replayKey("two"), recordingID: first)
            try expectEqual(cache.clip(at: 0, matching: replayKey("one")), nil, "unfinished reading")
            cache.complete(recordingID: first)
            try expectEqual(cache.clip(at: 0, matching: replayKey("one")), clip, "first chunk")
            try expectEqual(cache.clip(at: 1, matching: replayKey("two")), clip, "second chunk")
            let next = cache.beginRecording()
            cache.record(clip, key: replayKey("new"), recordingID: next)
            cache.complete(recordingID: next)
            try expectEqual(cache.clip(at: 0, matching: replayKey("one")), nil, "old text discarded")
            try expectEqual(cache.clip(at: 1, matching: replayKey("two")), nil, "old tail discarded")
        },
        TestCase(name: "replay cache rejects stale completion after clipboard invalidation") {
            var cache = SpeechReplayCache()
            let old = cache.beginRecording()
            cache.invalidate()
            let current = cache.beginRecording()
            let clip = AudioClip(data: Data([1]), format: .wav)
            cache.record(clip, key: replayKey("old"), recordingID: old)
            cache.complete(recordingID: old)
            cache.record(clip, key: replayKey("new"), recordingID: current)
            cache.complete(recordingID: current)
            try expectEqual(cache.clip(at: 0, matching: replayKey("old")), nil, "stale text")
            try expectEqual(cache.clip(at: 0, matching: replayKey("new")), clip, "new recording survives")
        },
        TestCase(name: "replay cache bounds combined text and audio and discards oversized recordings") {
            var cache = SpeechReplayCache(maximumBytes: 8)
            let clip = AudioClip(data: Data([1, 2, 3]), format: .wav)
            let recording = cache.beginRecording()
            cache.record(clip, key: replayKey("one"), recordingID: recording)
            cache.record(clip, key: replayKey("two"), recordingID: recording)
            cache.complete(recordingID: recording)
            try expectEqual(cache.clip(at: 0, matching: replayKey("one")), nil, "no partial oversized recording")
        },
        TestCase(name: "replay cache requires the voice and loaded model generation to match") {
            var cache = SpeechReplayCache()
            let clip = AudioClip(data: Data([1]), format: .wav)
            let recording = cache.beginRecording()
            cache.record(clip, key: replayKey("hello"), recordingID: recording)
            cache.complete(recordingID: recording)
            try expectEqual(cache.clip(at: 0, matching: replayKey("hello", voice: "bf_emma")), nil, "voice changed")
            try expectEqual(cache.clip(at: 0, matching: replayKey("hello", generation: 2)), nil, "model reloaded")
        },
        TestCase(name: "replay coordinator replays a completed reading without synthesis") {
            let synth = ReplayTestSynthesizer()
            let player = ReplayTestPlayer()
            let coordinator = SpeechCoordinator(synthesizer: synth, player: player)
            try await readReplayFixture(coordinator, id: "first")
            try await readReplayFixture(coordinator, id: "second")
            let calls = await synth.callCount
            let plays = await player.playCount
            try expectEqual(calls, 2, "each chunk synthesized once")
            try expectEqual(plays, 4, "both readings played")
            await coordinator.invalidateReplayCache()
            try await readReplayFixture(coordinator, id: "after-copy")
            let afterCopy = await synth.callCount
            try expectEqual(afterCopy, 4, "new clipboard revision prevents reuse")
        },
        TestCase(name: "replay coordinator saves the generated audio identity rather than an earlier lookup") {
            let synth = ReplayTestSynthesizer(changeGenerationOnFirstSynthesis: true)
            let coordinator = SpeechCoordinator(synthesizer: synth, player: ReplayTestPlayer())
            try await readReplayFixture(coordinator, id: "first")
            try await readReplayFixture(coordinator, id: "replay")
            let calls = await synth.callCount
            try expectEqual(calls, 2, "audio uses the identity returned with synthesis")
        },
        TestCase(name: "replay coordinator invalidation preserves playback and blocks a late cache save") {
            let synth = ReplayTestSynthesizer()
            let player = ReplayTestPlayer(blockFirst: true)
            let coordinator = SpeechCoordinator(synthesizer: synth, player: player)
            try await coordinator.startSession(id: "active") { _ in }
            _ = try await coordinator.enqueue(text: "one", voice: "af_heart", speed: 1)
            await coordinator.finishInput()
            await player.waitUntilPlaying()
            await coordinator.invalidateReplayCache()
            let stops = await player.stopCount
            let active = await coordinator.hasActiveSession
            try expectEqual(stops, 0, "copying must not stop playback")
            try expect(active, "active reading continues")
            await player.release()
            await coordinator.waitUntilFinished(sessionID: "active")
            try await coordinator.startSession(id: "repeated") { _ in }
            _ = try await coordinator.enqueue(text: "one", voice: "af_heart", speed: 1)
            await coordinator.finishInput()
            await coordinator.waitUntilFinished(sessionID: "repeated")
            let calls = await synth.callCount
            try expectEqual(calls, 2, "late completion did not restore invalidated audio")
        },
        TestCase(name: "replay coordinator does not save failed readings") {
            let synth = ReplayTestSynthesizer(failSecond: true)
            let coordinator = SpeechCoordinator(synthesizer: synth, player: ReplayTestPlayer())
            try await readReplayFixture(coordinator, id: "failed")
            try await readReplayFixture(coordinator, id: "retry")
            let calls = await synth.callCount
            try expectEqual(calls, 4, "successful prefix of a failed reading is not cached")
        },
    ]
}

private func readReplayFixture(_ coordinator: SpeechCoordinator, id: String) async throws {
    try await coordinator.startSession(id: id) { _ in }
    _ = try await coordinator.enqueue(text: "one", voice: "af_heart", speed: 1)
    _ = try await coordinator.enqueue(text: "two", voice: "af_heart", speed: 1)
    await coordinator.finishInput()
    await coordinator.waitUntilFinished(sessionID: id)
}

private actor ReplayTestSynthesizer: SpeechSynthesizing {
    private(set) var callCount = 0
    private let failSecond: Bool
    private let changeGenerationOnFirstSynthesis: Bool
    private var generation: UInt64 = 1

    init(failSecond: Bool = false, changeGenerationOnFirstSynthesis: Bool = false) {
        self.failSecond = failSecond
        self.changeGenerationOnFirstSynthesis = changeGenerationOnFirstSynthesis
    }

    func replayKey(for request: SpeechRequest) -> SpeechReplayKey? {
        SpeechReplayKey(modelID: .kokoro, modelGeneration: generation, request: request)
    }

    func synthesize(_ request: SpeechRequest) throws -> AudioClip {
        callCount += 1
        if changeGenerationOnFirstSynthesis, callCount == 1 { generation += 1 }
        if failSecond, callCount == 2 { throw TestFailure(description: "fixture failure") }
        return AudioClip(data: Data(request.input.utf8), format: .wav)
    }

    func synthesizeForReplay(_ request: SpeechRequest) throws -> ReplayableSpeech {
        ReplayableSpeech(clip: try synthesize(request), key: replayKey(for: request))
    }
}

private actor ReplayTestPlayer: AudioPlaying {
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private let blockFirst: Bool
    private var completion: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []

    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }

    func play(_ clip: AudioClip) async {
        playCount += 1
        started.forEach { $0.resume() }
        started.removeAll()
        if blockFirst, playCount == 1 {
            await withCheckedContinuation { completion = $0 }
        }
    }

    func waitUntilPlaying() async {
        if playCount > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release() { completion?.resume(); completion = nil }
    func stop() { stopCount += 1; release() }
    func pause() {}
    func resume() {}
}
