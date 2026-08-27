import Foundation

struct LanguageResourceStager: @unchecked Sendable {
    let roots: [URL]
    let cacheRootURL: URL
    private let fileManager: FileManager

    init(
        roots: [URL],
        cacheRootURL: URL = Self.defaultCacheRoot(),
        fileManager: FileManager = .default
    ) {
        self.roots = roots.map(\.standardizedFileURL)
        self.cacheRootURL = cacheRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func stage() throws {
        let englishTarget = cacheRootURL
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent("beshkenadze_kitten-tts-g2p", isDirectory: true)
        let lexiconTarget = cacheRootURL
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent("beshkenadze_kokoro-ipa-lexicons", isDirectory: true)
        try fileManager.createDirectory(at: englishTarget, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: lexiconTarget, withIntermediateDirectories: true)

        for root in roots {
            let english = root.appendingPathComponent("en", isDirectory: true)
            if let files = try? fileManager.contentsOfDirectory(
                at: english,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for source in files where !source.hasDirectoryPath {
                    try copyIfNeeded(source, to: englishTarget.appendingPathComponent(source.lastPathComponent))
                }
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let source as URL in enumerator
                where source.lastPathComponent.hasSuffix("_lexicon.tsv")
            {
                try copyIfNeeded(source, to: lexiconTarget.appendingPathComponent(source.lastPathComponent))
            }
        }

        let englishConfig = englishTarget.appendingPathComponent("config.json")
        if !fileManager.fileExists(atPath: englishConfig.path) {
            try Data("{}".utf8).write(to: englishConfig, options: .atomic)
        }
    }

    private func copyIfNeeded(_ source: URL, to destination: URL) throws {
        let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let destinationSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard sourceSize != destinationSize else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func defaultCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["HF_HUB_CACHE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let path = environment["HF_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }
}
