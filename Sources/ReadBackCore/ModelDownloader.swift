import Foundation

public enum ModelDownloadError: Error, Equatable, Sendable {
    case failed(Int32)
}

public actor HuggingFaceModelDownloader {
    public init() {}

    public func download(_ descriptor: ModelDescriptor, to directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "uvx", "--from", "huggingface-hub", "hf", "download",
            descriptor.repository,
            "--revision", descriptor.revision,
            "--local-dir", directoryURL.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelDownloadError.failed(process.terminationStatus)
        }
    }
}
