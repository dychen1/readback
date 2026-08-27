public struct ModelManagerPresentation: Equatable, Sendable {
    public let snapshot: ModelManagerSnapshot
    public let installed: [ModelSnapshot]
    public let available: [ModelSnapshot]

    public init(snapshot: ModelManagerSnapshot) {
        self.snapshot = snapshot
        installed = snapshot.models.filter { Self.isInstalled($0.storageState) }
        available = snapshot.models.filter { !Self.isInstalled($0.storageState) }
    }

    public var activeModel: ModelSnapshot? {
        guard let id = snapshot.activeModelID else { return nil }
        return installed.first { $0.id == id }
    }

    public var activeLanguages: [ModelLanguageSnapshot] {
        activeModel?.languages.filter(\.isInstalled) ?? []
    }

    public var activeVoices: [ModelVoiceDefinition] {
        activeLanguages.flatMap(\.voices)
    }

    public var isChangingModel: Bool {
        if case .switching = snapshot.operation { return true }
        return false
    }

    private static func isInstalled(_ state: ModelStorageState) -> Bool {
        switch state {
        case .bundled, .installed, .localAvailable:
            true
        default:
            false
        }
    }
}
