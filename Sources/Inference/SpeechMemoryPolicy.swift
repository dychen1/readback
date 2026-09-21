import Dispatch
import MLX

/// MLX's default buffer cache scales with system RAM. Speech needs a much
/// smaller reuse pool; model weights remain live independently of this limit.
public enum SpeechMemoryPolicy {
    public static let cacheLimit = 64 * 1024 * 1024
    private static let monitor = MemoryPressureMonitor()

    public static func configure() {
        _ = monitor
    }
}

private final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init() {
        Memory.cacheLimit = SpeechMemoryPolicy.cacheLimit
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(label: "ReadBack.memory-pressure", qos: .utility)
        )
        // MLX serializes this operation with evaluation and frees only cached
        // buffers. Active tensors, including the loaded model, remain valid.
        source.setEventHandler { Memory.clearCache() }
        source.activate()
    }

    deinit { source.cancel() }
}
