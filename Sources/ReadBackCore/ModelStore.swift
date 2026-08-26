import Foundation

public struct InstalledModel: Equatable, Sendable {
    public let descriptor: ModelDescriptor
    public let directoryURL: URL

    public init(descriptor: ModelDescriptor, directoryURL: URL) {
        self.descriptor = descriptor
        self.directoryURL = directoryURL
    }
}

public enum ModelStoreError: Error, Equatable, Sendable {
    case unknownModel(String)
    case unsafeModelPath(URL)
}

public actor ModelStore {
    private let rootURL: URL
    private let modelsByID: [String: ModelDescriptor]
    private let fileManager: FileManager

    public init(
        rootURL: URL,
        supportedModels: [ModelDescriptor],
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.modelsByID = Dictionary(uniqueKeysWithValues: supportedModels.map { ($0.id, $0) })
        self.fileManager = fileManager
    }

    public func directoryURL(for modelID: String) throws -> URL {
        guard let descriptor = modelsByID[modelID] else {
            throw ModelStoreError.unknownModel(modelID)
        }

        let candidate = rootURL
            .appendingPathComponent(descriptor.directoryName, isDirectory: true)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent().standardizedFileURL == rootURL else {
            throw ModelStoreError.unsafeModelPath(candidate)
        }
        return candidate
    }

    public func installedModels() throws -> [InstalledModel] {
        try modelsByID.values
            .sorted { $0.id < $1.id }
            .compactMap { descriptor in
                let directoryURL = try directoryURL(for: descriptor.id)
                guard isCompleteModel(at: directoryURL) else {
                    return nil
                }
                return InstalledModel(descriptor: descriptor, directoryURL: directoryURL)
            }
    }

    public func delete(modelID: String) throws {
        let modelURL = try directoryURL(for: modelID)
        guard fileManager.fileExists(atPath: modelURL.path) else {
            return
        }
        try fileManager.removeItem(at: modelURL)
    }

    private func isCompleteModel(at directoryURL: URL) -> Bool {
        let requiredPaths = [
            directoryURL.appendingPathComponent("config.json").path,
            directoryURL.appendingPathComponent("kokoro-v1_0.safetensors").path,
            directoryURL.appendingPathComponent("voices/af_heart.safetensors").path,
        ]
        return requiredPaths.allSatisfy(fileManager.fileExists(atPath:))
    }
}
