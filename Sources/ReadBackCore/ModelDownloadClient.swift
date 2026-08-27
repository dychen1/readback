import Foundation

public protocol ModelAssetDownloading: Sendable {
    func download(from source: URL, to destination: URL) async throws
}

public enum ModelDownloadClientError: Error, Equatable, Sendable {
    case invalidResponse(Int)
}

public actor URLSessionModelAssetDownloader: ModelAssetDownloading {
    private let session: URLSession
    private let fileManager: FileManager

    public init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    public func download(from source: URL, to destination: URL) async throws {
        let (temporaryURL, response) = try await session.download(from: source)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw ModelDownloadClientError.invalidResponse(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }
}
