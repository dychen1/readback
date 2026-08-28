import Foundation

public struct ModelDownloadProgress: Equatable, Sendable {
    public let bytesReceived: Int64
    public let totalBytes: Int64

    public init(bytesReceived: Int64, totalBytes: Int64) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }
}

public protocol ModelAssetDownloading: Sendable {
    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws
    func cancel() async
}

public extension ModelAssetDownloading {
    func download(from source: URL, to destination: URL) async throws {
        try await download(from: source, to: destination) { _ in }
    }

    func cancel() async {}
}

public enum ModelDownloadClientError: Error, Equatable, Sendable {
    case invalidResponse(Int)
}

public actor URLSessionModelAssetDownloader: ModelAssetDownloading {
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private var activeOperation: URLSessionDownloadOperation?

    public init(
        configuration: URLSessionConfiguration = .default,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public init(session: URLSession, fileManager: FileManager = .default) {
        configuration = session.configuration
        self.fileManager = fileManager
    }

    public func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        let operation = URLSessionDownloadOperation(
            configuration: configuration,
            source: source,
            destination: destination,
            fileManager: fileManager,
            progress: progress
        )
        activeOperation = operation
        defer { activeOperation = nil }
        try await operation.run()
    }

    public func cancel() async {
        activeOperation?.cancel()
    }
}

private final class URLSessionDownloadOperation: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let source: URL
    private let destination: URL
    private let fileManager: FileManager
    private let progress: @Sendable (ModelDownloadProgress) async -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var completionError: Error?
    private var session: URLSession!
    private var task: URLSessionDownloadTask!

    init(
        configuration: URLSessionConfiguration,
        source: URL,
        destination: URL,
        fileManager: FileManager,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) {
        self.source = source
        self.destination = destination
        self.fileManager = fileManager
        self.progress = progress
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: source)
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let handler = progress
        Task {
            await handler(
                ModelDownloadProgress(
                    bytesReceived: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            completionError = ModelDownloadClientError.invalidResponse(
                (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            )
            return
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            completionError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(with: error ?? completionError)
    }

    private func finish(with error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
