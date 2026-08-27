import CryptoKit
import Foundation

public struct ModelLibraryPaths: Equatable, Sendable {
    public let managedModelsURL: URL
    public let downloadsURL: URL
    public let localRegistrationURL: URL

    public init(
        managedModelsURL: URL,
        downloadsURL: URL,
        localRegistrationURL: URL
    ) {
        self.managedModelsURL = managedModelsURL.standardizedFileURL
        self.downloadsURL = downloadsURL.standardizedFileURL
        self.localRegistrationURL = localRegistrationURL.standardizedFileURL
    }
}

public enum ModelLocation: Equatable, Sendable {
    case bundled(URL)
    case managed(URL)
    case local(URL)

    public var directoryURL: URL {
        switch self {
        case .bundled(let url), .managed(let url), .local(let url): url
        }
    }
}

public enum ModelStorageState: Equatable, Sendable {
    case bundled
    case notInstalled
    case downloading(progress: Double)
    case installed
    case localAvailable
    case localMissing
    case invalid(reason: String)
}

public enum ModelLibraryError: Error, Equatable, Sendable {
    case unknownModel(ModelID)
    case notInstalled(ModelID)
    case bundledModelCannotBeRemoved
    case activeDownload
    case localDirectoryMissing
    case unsupportedLocalModel
    case integrityCheckFailed(ModelID, path: String)
    case invalidDownloadURL(ModelID, path: String)
}

public protocol ModelLibraryProtocol: Sendable {
    func storageState(for id: ModelID) async -> ModelStorageState
    func location(for id: ModelID) async throws -> ModelLocation
    func runtimeProfile(for id: ModelID) async throws -> MLXRuntimeProfile
    func displayName(for id: ModelID) async -> String?
    func isLanguageInstalled(_ code: String, for id: ModelID) async -> Bool
    func install(_ id: ModelID) async throws
    func installLanguage(_ code: String, for id: ModelID) async throws
    func registerLocalModel(at directory: URL) async throws
    func remove(_ id: ModelID) async throws
}

public extension ModelLibraryProtocol {
    func displayName(for id: ModelID) async -> String? { nil }
}

public actor ModelLibrary: ModelLibraryProtocol {
    private let catalog: CuratedModelCatalog
    private let paths: ModelLibraryPaths
    private let bundledModels: [ModelID: URL]
    private let downloader: any ModelAssetDownloading
    private let fileManager: FileManager
    private let localStore: LocalModelRegistrationStore
    private var activeDownloadID: ModelID?
    private var accessedLocalURL: URL?

    public init(
        catalog: CuratedModelCatalog,
        paths: ModelLibraryPaths,
        bundledModels: [ModelID: URL],
        downloader: any ModelAssetDownloading = URLSessionModelAssetDownloader(),
        fileManager: FileManager = .default
    ) {
        self.catalog = catalog
        self.paths = paths
        self.bundledModels = bundledModels.mapValues(\.standardizedFileURL)
        self.downloader = downloader
        self.fileManager = fileManager
        localStore = LocalModelRegistrationStore(fileURL: paths.localRegistrationURL)
    }

    public func storageState(for id: ModelID) async -> ModelStorageState {
        if id == .local {
            do {
                guard let directory = try localStore.resolve() else { return .notInstalled }
                return fileManager.fileExists(atPath: directory.path)
                    ? .localAvailable
                    : .localMissing
            } catch {
                return .invalid(reason: error.localizedDescription)
            }
        }
        guard let model = try? catalog.model(id: id) else { return .notInstalled }
        if model.distribution == .bundled {
            guard let directory = bundledModels[id] else { return .notInstalled }
            return assetsExist(model.requiredAssets, under: directory)
                ? .bundled
                : .notInstalled
        }
        if activeDownloadID == id { return .downloading(progress: 0) }
        let directory = managedDirectory(for: model)
        return assetsExist(model.requiredAssets, under: directory) ? .installed : .notInstalled
    }

    public func location(for id: ModelID) async throws -> ModelLocation {
        if id == .local {
            let registration = try localStore.load()
            guard let directory = try localStore.resolve() else {
                throw ModelLibraryError.notInstalled(id)
            }
            guard fileManager.fileExists(atPath: directory.path) else {
                throw ModelLibraryError.localDirectoryMissing
            }
            if registration?.usesSecurityScope == true, accessedLocalURL != directory {
                accessedLocalURL?.stopAccessingSecurityScopedResource()
                guard directory.startAccessingSecurityScopedResource() else {
                    throw ModelLibraryError.localDirectoryMissing
                }
                accessedLocalURL = directory
            }
            return .local(directory)
        }
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        if model.distribution == .bundled {
            guard let directory = bundledModels[id],
                  assetsExist(model.requiredAssets, under: directory)
            else { throw ModelLibraryError.notInstalled(id) }
            return .bundled(directory)
        }
        let directory = managedDirectory(for: model)
        guard assetsExist(model.requiredAssets, under: directory) else {
            throw ModelLibraryError.notInstalled(id)
        }
        return .managed(directory)
    }

    public func runtimeProfile(for id: ModelID) async throws -> MLXRuntimeProfile {
        if id == .local {
            guard let registration = try localStore.load() else {
                throw ModelLibraryError.notInstalled(id)
            }
            return registration.runtimeProfile
        }
        do {
            return try catalog.model(id: id).runtimeProfile
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
    }

    public func displayName(for id: ModelID) async -> String? {
        guard id == .local else { return nil }
        return try? localStore.load()?.displayName
    }

    public func isLanguageInstalled(_ code: String, for id: ModelID) async -> Bool {
        guard let model = try? catalog.model(id: id),
              let language = model.languages.first(where: { $0.code == code })
        else { return false }
        switch language.distribution {
        case .bundled, .includedWithModel:
            return true
        case .downloadable:
            let root = managedDirectory(for: model)
                .appendingPathComponent("Languages", isDirectory: true)
                .appendingPathComponent(code, isDirectory: true)
            return assetsExist(language.requiredAssets, under: root)
        }
    }

    public func install(_ id: ModelID) async throws {
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        guard model.distribution == .downloadable else { return }
        guard activeDownloadID == nil else { throw ModelLibraryError.activeDownload }
        activeDownloadID = id
        defer { activeDownloadID = nil }

        try fileManager.createDirectory(at: paths.downloadsURL, withIntermediateDirectories: true)
        let operationURL = paths.downloadsURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let stagedModelURL = operationURL.appendingPathComponent("model", isDirectory: true)
        defer { try? fileManager.removeItem(at: operationURL) }
        try await download(
            model.requiredAssets,
            for: model,
            to: stagedModelURL
        )
        let destination = managedDirectory(for: model)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedModelURL, to: destination)
    }

    public func installLanguage(_ code: String, for id: ModelID) async throws {
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        guard let language = model.languages.first(where: { $0.code == code }) else {
            throw ModelLibraryError.unknownModel(id)
        }
        guard language.distribution == .downloadable else { return }
        do {
            _ = try await location(for: id)
        } catch {
            throw ModelLibraryError.notInstalled(id)
        }
        guard activeDownloadID == nil else { throw ModelLibraryError.activeDownload }
        activeDownloadID = id
        defer { activeDownloadID = nil }

        let operationURL = paths.downloadsURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let stagedURL = operationURL.appendingPathComponent("language", isDirectory: true)
        defer { try? fileManager.removeItem(at: operationURL) }
        try await download(language.requiredAssets, for: model, to: stagedURL)

        let modelRoot = managedDirectory(for: model)
        let destination = modelRoot
            .appendingPathComponent("Languages", isDirectory: true)
            .appendingPathComponent(code, isDirectory: true)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedURL, to: destination)
        try publishLanguageVoices(from: destination, for: id)
    }

    public func registerLocalModel(at directory: URL) async throws {
        let resolved = directory.standardizedFileURL
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw ModelLibraryError.localDirectoryMissing
        }
        let profile = try detectRuntimeProfile(in: resolved)
        accessedLocalURL?.stopAccessingSecurityScopedResource()
        accessedLocalURL = nil
        try localStore.save(directory: resolved, profile: profile)
    }

    public func remove(_ id: ModelID) async throws {
        if id == .local {
            accessedLocalURL?.stopAccessingSecurityScopedResource()
            accessedLocalURL = nil
            try localStore.remove()
            return
        }
        let model: CuratedModelDefinition
        do {
            model = try catalog.model(id: id)
        } catch {
            throw ModelLibraryError.unknownModel(id)
        }
        guard model.distribution != .bundled else {
            throw ModelLibraryError.bundledModelCannotBeRemoved
        }
        let directory = managedDirectory(for: model)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func managedDirectory(for model: CuratedModelDefinition) -> URL {
        paths.managedModelsURL
            .appendingPathComponent(model.id.rawValue, isDirectory: true)
            .appendingPathComponent(model.revision, isDirectory: true)
            .standardizedFileURL
    }

    private func publishLanguageVoices(from languageURL: URL, for id: ModelID) throws {
        guard let modelURL = bundledModels[id] else { return }
        let sourceURL = languageURL.appendingPathComponent("voices", isDirectory: true)
        guard let voices = try? fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let targetURL = modelURL.appendingPathComponent("voices", isDirectory: true)
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        for voice in voices where voice.pathExtension == "safetensors" {
            let target = targetURL.appendingPathComponent(voice.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createSymbolicLink(at: target, withDestinationURL: voice)
        }
    }

    private func assetsExist(_ assets: [ModelAssetDefinition], under root: URL) -> Bool {
        guard fileManager.fileExists(atPath: root.path) else { return false }
        return assets.allSatisfy { asset in
            let url = root.appendingPathComponent(asset.relativePath)
            guard fileManager.fileExists(atPath: url.path),
                  let values = try? url.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.fileSizeKey])
            else { return false }
            return Int64(values.fileSize ?? -1) == asset.byteCount
        }
    }

    private func download(
        _ assets: [ModelAssetDefinition],
        for model: CuratedModelDefinition,
        to root: URL
    ) async throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for asset in assets {
            let destination = root.appendingPathComponent(asset.relativePath)
            let source = try sourceURL(for: asset, model: model)
            try await downloader.download(from: source, to: destination)
            guard try validate(asset, at: destination) else {
                throw ModelLibraryError.integrityCheckFailed(
                    model.id,
                    path: asset.relativePath
                )
            }
        }
    }

    private func sourceURL(
        for asset: ModelAssetDefinition,
        model: CuratedModelDefinition
    ) throws -> URL {
        if let explicit = asset.downloadURL { return explicit }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(model.repository)/resolve/\(model.revision)/\(asset.relativePath)"
        guard let url = components.url else {
            throw ModelLibraryError.invalidDownloadURL(
                model.id,
                path: asset.relativePath
            )
        }
        return url
    }

    private func validate(_ asset: ModelAssetDefinition, at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == asset.byteCount else { return false }
        return try sha256(of: url) == asset.sha256.lowercased()
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func detectRuntimeProfile(in directory: URL) throws -> MLXRuntimeProfile {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ModelLibraryError.unsupportedLocalModel }
        let modelType = (object["model_type"] as? String)?.lowercased()
        let isKokoro = modelType == "kokoro"
            || (object["istftnet"] != nil && object["plbert"] != nil)
        guard isKokoro else { throw ModelLibraryError.unsupportedLocalModel }
        guard containsWeights(in: directory) else {
            throw ModelLibraryError.unsupportedLocalModel
        }
        return .kokoro
    }

    private func containsWeights(in directory: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            return true
        }
        return false
    }
}
