import Foundation

public struct RuntimePaths: Equatable, Sendable {
    public let supportDirectory: URL
    public let modelsDirectory: URL
    public let configurationFile: URL

    public init(supportDirectory: URL, modelsDirectory: URL) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.modelsDirectory = modelsDirectory.standardizedFileURL
        self.configurationFile = supportDirectory.appendingPathComponent("config.json")
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleURL: URL? = Bundle.main.bundleURL
    ) -> RuntimePaths {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ReadBack", isDirectory: true)

        if let override = environment["READBACK_MODELS_DIR"], !override.isEmpty {
            return RuntimePaths(
                supportDirectory: support,
                modelsDirectory: URL(fileURLWithPath: override, isDirectory: true)
            )
        }

        let developmentRoots = [
            currentDirectory,
            bundleURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
        ].compactMap { $0 }
        if let projectDirectory = developmentRoots.first(where: {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("Package.swift").path
            )
        }) {
            return RuntimePaths(
                supportDirectory: support,
                modelsDirectory: projectDirectory.appendingPathComponent("models", isDirectory: true)
            )
        }
        return RuntimePaths(
            supportDirectory: support,
            modelsDirectory: support.appendingPathComponent("models", isDirectory: true)
        )
    }
}

public struct AppConfigurationStore: Sendable {
    public init() {}

    public func loadOrCreate(at url: URL, modelsDirectory: URL) throws -> AppConfiguration {
        try migrateLegacyConfigurationIfNeeded(to: url)
        if FileManager.default.fileExists(atPath: url.path) {
            var configuration = try JSONDecoder().decode(
                AppConfiguration.self,
                from: Data(contentsOf: url)
            )
            let currentDefault = modelsDirectory.standardizedFileURL
            if configuration.modelDirectory.standardizedFileURL != currentDefault,
               !FileManager.default.fileExists(atPath: configuration.modelDirectory.path)
            {
                configuration.modelDirectory = currentDefault
                try save(configuration, at: url)
            }
            return configuration
        }
        let configuration = AppConfiguration.default(modelDirectory: modelsDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try save(configuration, at: url)
        return configuration
    }

    public func save(_ configuration: AppConfiguration, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    private func migrateLegacyConfigurationIfNeeded(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              url.deletingLastPathComponent().lastPathComponent == "ReadBack"
        else { return }

        let legacyURL = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ReadBackVoice", isDirectory: true)
            .appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: legacyURL, to: url)
    }
}
