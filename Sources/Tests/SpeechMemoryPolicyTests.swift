import Foundation
import MLX
import ReadBackCore
import ReadBackInference

private final class MemoryCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func record(_ call: String) { lock.withLock { calls.append(call) } }
    func snapshot() -> [String] { lock.withLock { calls } }
}

private actor MemoryTestAdapter: SpeechRuntimeAdapter {
    enum Mode: Sendable { case success, failure, empty, suspended }
    let kind: SpeechRuntimeKind = .kokoro
    let sampleRate = 24_000
    let mode: Mode
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?

    init(_ mode: Mode) { self.mode = mode }
    func validateModel(at directory: URL) {}
    func loadModel(at directory: URL) {}
    func unloadModel() { continuation?.finish(); continuation = nil }

    func synthesize(_ request: ResolvedSpeechRequest) throws -> AsyncThrowingStream<[Float], Error> {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if mode == .failure { throw TestFailure(description: "synthesis failed") }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        if mode == .suspended {
            self.continuation = continuation
        } else {
            if mode == .success { continuation.yield([0.1, -0.1]) }
            continuation.finish()
        }
        return stream
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private struct MemoryTestRegistry: SpeechRuntimeRegistry {
    let adapter: MemoryTestAdapter
    func makeAdapter(for kind: SpeechRuntimeKind) -> any SpeechRuntimeAdapter { adapter }
}

func speechMemoryPolicyTests() -> [TestCase] {
    [
        TestCase(name: "MLX memory cleanup runs after success and synthesis errors") {
            for mode in [MemoryTestAdapter.Mode.success, .failure, .empty] {
                let calls = MemoryCallRecorder()
                let session = MLXSpeechModelSession(
                    registry: MemoryTestRegistry(adapter: MemoryTestAdapter(mode)),
                    clearCache: { calls.record("clear") },
                    configureMemory: { calls.record("configure") }
                )
                try await session.load(from: FileManager.default.temporaryDirectory, profile: .kokoro)
                try expectEqual(calls.snapshot(), ["configure", "clear"], "configure before load, clear after load")
                var failed = false
                do { _ = try await session.synthesize(memoryTestRequest("hello")) }
                catch { failed = true }
                try expectEqual(failed, mode != .success, "expected synthesis outcome")
                try expectEqual(calls.snapshot(), ["configure", "clear", "clear"], "cleanup after every outcome")
            }
        },
        TestCase(name: "MLX memory cleanup runs when a waiting synthesis is cancelled") {
            let calls = MemoryCallRecorder()
            let adapter = MemoryTestAdapter(.suspended)
            let session = MLXSpeechModelSession(
                registry: MemoryTestRegistry(adapter: adapter),
                clearCache: { calls.record("clear") },
                configureMemory: { calls.record("configure") }
            )
            try await session.load(from: FileManager.default.temporaryDirectory, profile: .kokoro)
            let request = Task { try await session.synthesize(memoryTestRequest("cancel")) }
            await adapter.waitUntilStarted()
            request.cancel()
            do {
                _ = try await request.value
                throw TestFailure(description: "cancelled synthesis returned audio")
            } catch is CancellationError {}
            try expectEqual(calls.snapshot(), ["configure", "clear", "clear"], "cleanup on cancellation")
            await session.unload()
        },
        TestCase(name: "native Kokoro memory stays bounded after varied requests") {
            let environment = ProcessInfo.processInfo.environment
            guard environment["READBACK_RUN_MEMORY_SMOKE"] == "1" else { return }
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let model = environment["READBACK_MEMORY_MODEL_PATH"].map { URL(fileURLWithPath: $0) }
                ?? root.appendingPathComponent("models/Kokoro-82M-bf16")
            let languages = environment["READBACK_MEMORY_LANGUAGES_PATH"].map { URL(fileURLWithPath: $0) }
                ?? root.appendingPathComponent("models/Languages")
            let session = MLXSpeechModelSession(languageResourceRoots: [languages])
            try await session.load(from: model, profile: .kokoro)
            let texts = [
                "test, hello world",
                "The small application reads text aloud. It should release temporary memory after each sentence.",
                "Today we are measuring the memory used by speech synthesis. The model stays loaded while several sentences run. Each sentence has a different length, which creates temporary arrays of different sizes. We measure the memory again after the request has finished.",
                "A cache can keep old buffers for later requests. That can improve speed, but the application must set a suitable limit. Otherwise a small speech model can hold much more memory than its weights require. This experiment compares the default behavior with a small cache and records the active memory separately.",
            ]
            for text in texts {
                let clip = try await session.synthesize(memoryTestRequest(text))
                try expectEqual(String(decoding: clip.data.prefix(4), as: UTF8.self), "RIFF", "valid WAV")
                try expect(clip.data.count > 44, "nonempty audio")
                // Let the upstream stream producer release its final references.
                try await Task.sleep(for: .milliseconds(200))
                let memory = Memory.snapshot()
                print("MEMORY active=\(memory.activeMemory) cache=\(memory.cacheMemory) peak=\(memory.peakMemory)")
                try expect(memory.cacheMemory < 96 * 1024 * 1024, "idle cache remains bounded, including allocator overshoot")
                try expect(memory.activeMemory < 512 * 1024 * 1024, "live tensors return to the model baseline")
            }
            await session.unload()
            try expect(Memory.activeMemory < 1024 * 1024, "model tensors released on unload")
        },
    ]
}

private func memoryTestRequest(_ text: String) -> SpeechRequest {
    SpeechRequest(input: text, voice: "af_heart", languageCode: "a", speed: 1, format: .wav)
}
