import AppKit

/// Watches only the pasteboard revision; it does not read clipboard contents.
@MainActor
public final class ClipboardChangeMonitor {
    private let changeCount: @MainActor () -> Int
    private let onChange: @MainActor @Sendable () async -> Void
    private var lastChangeCount: Int
    private var pollingTask: Task<Void, Never>?
    private var invalidationTask: Task<Void, Never>?

    public init(
        changeCount: @escaping @MainActor () -> Int = { NSPasteboard.general.changeCount },
        onChange: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.changeCount = changeCount
        self.onChange = onChange
        lastChangeCount = changeCount()
    }

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                await self?.checkForChanges()
            }
        }
    }

    /// Also called before a clipboard reading, so a quick copy/read shortcut
    /// cannot replay stale audio between timer ticks.
    public func checkForChanges() async {
        let count = changeCount()
        if count != lastChangeCount {
            lastChangeCount = count
            let prior = invalidationTask
            let onChange = self.onChange
            invalidationTask = Task {
                await prior?.value
                await onChange()
            }
        }
        let revision = lastChangeCount
        await invalidationTask?.value
        if revision == lastChangeCount { invalidationTask = nil }
    }

    deinit { pollingTask?.cancel() }
}
