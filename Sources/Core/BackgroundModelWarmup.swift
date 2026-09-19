public actor BackgroundModelWarmup {
    private let operation: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    public init(operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [operation] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    public func cancel() async {
        task?.cancel()
        await task?.value
        task = nil
    }
}
