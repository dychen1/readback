import Foundation

public struct ModelWorkspace: @unchecked Sendable {
    private let bundledModelURL: URL
    private let installedLanguagesURL: URL
    public let runtimeModelURL: URL
    private let fileManager: FileManager

    public init(
        bundledModelURL: URL,
        installedLanguagesURL: URL,
        runtimeModelURL: URL,
        fileManager: FileManager = .default
    ) {
        self.bundledModelURL = bundledModelURL.standardizedFileURL
        self.installedLanguagesURL = installedLanguagesURL.standardizedFileURL
        self.runtimeModelURL = runtimeModelURL.standardizedFileURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func prepare() throws -> URL {
        try fileManager.createDirectory(
            at: runtimeModelURL.appendingPathComponent("voices", isDirectory: true),
            withIntermediateDirectories: true
        )
        for filename in ["config.json", "kokoro-v1_0.safetensors"] {
            try link(
                bundledModelURL.appendingPathComponent(filename),
                to: runtimeModelURL.appendingPathComponent(filename)
            )
        }

        let bundledVoiceIDs = Set(
            KokoroLanguagePackCatalog.bundled.flatMap { $0.voices.map(\.id) }
        )
        for voiceID in bundledVoiceIDs {
            try linkVoice(
                bundledModelURL
                    .appendingPathComponent("voices", isDirectory: true)
                    .appendingPathComponent("\(voiceID).safetensors")
            )
        }

        if let enumerator = fileManager.enumerator(
            at: installedLanguagesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator
                where fileURL.pathExtension == "safetensors"
                    && fileURL.deletingLastPathComponent().lastPathComponent == "voices"
            {
                try linkVoice(fileURL)
            }
        }
        return runtimeModelURL
    }

    private func linkVoice(_ source: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try link(
            source,
            to: runtimeModelURL
                .appendingPathComponent("voices", isDirectory: true)
                .appendingPathComponent(source.lastPathComponent)
        )
    }

    private func link(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: destination.path),
           URL(fileURLWithPath: existing).standardizedFileURL == source.standardizedFileURL
        {
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}
