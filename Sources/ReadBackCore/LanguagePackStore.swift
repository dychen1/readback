import Foundation

public enum LanguagePackStoreError: LocalizedError, Equatable, Sendable {
    case unknownPack(String)
    case invalidResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .unknownPack(let id):
            "Unknown language pack: \(id)"
        case .invalidResponse(let status):
            "The language-pack download failed with HTTP status \(status)."
        }
    }
}

public actor LanguagePackStore {
    public static let lexiconRevision = "a3d069caea9a2b63daed40834514431f73a2f11e"

    private let rootURL: URL
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        rootURL: URL,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.session = session
        self.fileManager = fileManager
    }

    public func isInstalled(_ pack: KokoroLanguagePack) -> Bool {
        if pack.isBundled { return true }
        let directory = rootURL.appendingPathComponent(pack.id, isDirectory: true)
        let voicesReady = pack.voices.allSatisfy { voice in
            fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent("voices", isDirectory: true)
                    .appendingPathComponent("\(voice.id).safetensors").path
            )
        }
        let lexiconReady = pack.lexiconFilename.map { filename in
            fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent("resources", isDirectory: true)
                    .appendingPathComponent(filename).path
            )
        } ?? true
        return voicesReady && lexiconReady
    }

    public func install(packID: String) async throws {
        guard let pack = KokoroLanguagePackCatalog.pack(id: packID) else {
            throw LanguagePackStoreError.unknownPack(packID)
        }
        guard !pack.isBundled else { return }

        let directory = rootURL.appendingPathComponent(pack.id, isDirectory: true)
        let voicesDirectory = directory.appendingPathComponent("voices", isDirectory: true)
        let resourcesDirectory = directory.appendingPathComponent("resources", isDirectory: true)
        try fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        for voice in pack.voices {
            let destination = voicesDirectory.appendingPathComponent("\(voice.id).safetensors")
            if !fileManager.fileExists(atPath: destination.path) {
                let source = URL(
                    string: "https://huggingface.co/\(ModelDescriptor.kokoro.repository)/resolve/\(ModelDescriptor.kokoro.revision)/voices/\(voice.id).safetensors"
                )!
                try await download(source, to: destination)
            }
        }
        if let filename = pack.lexiconFilename {
            let destination = resourcesDirectory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: destination.path) {
                let source = URL(
                    string: "https://huggingface.co/beshkenadze/kokoro-ipa-lexicons/resolve/\(Self.lexiconRevision)/\(filename)"
                )!
                try await download(source, to: destination)
            }
        }
    }

    private func download(_ source: URL, to destination: URL) async throws {
        let (temporaryURL, response) = try await session.download(from: source)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw LanguagePackStoreError.invalidResponse(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }
}
