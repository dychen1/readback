import Foundation

public struct LocalModelRegistration: Codable, Equatable, Sendable {
    public let modelID: ModelID
    public let displayName: String
    public let bookmarkData: Data
    public let lastKnownPath: String
    public let runtimeProfile: MLXRuntimeProfile
    public let usesSecurityScope: Bool

    public init(
        modelID: ModelID = .local,
        displayName: String,
        bookmarkData: Data,
        lastKnownPath: String,
        runtimeProfile: MLXRuntimeProfile,
        usesSecurityScope: Bool
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
        self.runtimeProfile = runtimeProfile
        self.usesSecurityScope = usesSecurityScope
    }
}

public struct LocalModelRegistrationStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func save(directory: URL, profile: MLXRuntimeProfile) throws {
        let bookmark: Data
        let usesSecurityScope: Bool
        do {
            bookmark = try directory.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            usesSecurityScope = true
        } catch {
            bookmark = try directory.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            usesSecurityScope = false
        }
        let registration = LocalModelRegistration(
            displayName: directory.lastPathComponent,
            bookmarkData: bookmark,
            lastKnownPath: directory.path,
            runtimeProfile: profile,
            usesSecurityScope: usesSecurityScope
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registration).write(to: fileURL, options: .atomic)
    }

    public func load() throws -> LocalModelRegistration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            LocalModelRegistration.self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func resolve() throws -> URL? {
        guard let registration = try load() else { return nil }
        var stale = false
        let options: URL.BookmarkResolutionOptions = registration.usesSecurityScope
            ? [.withSecurityScope, .withoutUI]
            : [.withoutUI]
        let resolved = try URL(
            resolvingBookmarkData: registration.bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).standardizedFileURL
        if stale {
            try save(directory: resolved, profile: registration.runtimeProfile)
        }
        return resolved
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
