import Foundation

public protocol MLXModelSession: Sendable {
    func load(from directory: URL, profile: MLXRuntimeProfile) async throws
    func synthesize(_ request: SpeechRequest) async throws -> AudioClip
    func unload() async
}

public enum ModelOrigin: Equatable, Sendable {
    case bundled
    case managedDownload
    case local
}

public enum ModelRuntimeState: Equatable, Sendable {
    case starting
    case loading(ModelID)
    case ready(ModelID)
    case unloading(ModelID)
    case failed(ModelID?, message: String)
}

public enum ModelOperation: Equatable, Sendable {
    case idle
    case installingModel(ModelID)
    case installingLanguage(modelID: ModelID, languageCode: String)
    case importingLocal
    case removing(ModelID)
    case switching(from: ModelID?, to: ModelID)
}

public struct ModelLanguageSnapshot: Equatable, Identifiable, Sendable {
    public var id: String { code }
    public let code: String
    public let displayName: String
    public let voices: [ModelVoiceDefinition]
    public let isInstalled: Bool
    public let canInstall: Bool

    public init(
        code: String,
        displayName: String,
        voices: [ModelVoiceDefinition],
        isInstalled: Bool,
        canInstall: Bool
    ) {
        self.code = code
        self.displayName = displayName
        self.voices = voices
        self.isInstalled = isInstalled
        self.canInstall = canInstall
    }
}

public struct ModelSnapshot: Equatable, Identifiable, Sendable {
    public let id: ModelID
    public let displayName: String
    public let origin: ModelOrigin
    public let storageState: ModelStorageState
    public let downloadSize: Int64?
    public let languages: [ModelLanguageSnapshot]
    public let canInstall: Bool
    public let canRemove: Bool
    public let canActivate: Bool

    public init(
        id: ModelID,
        displayName: String,
        origin: ModelOrigin,
        storageState: ModelStorageState,
        downloadSize: Int64? = nil,
        languages: [ModelLanguageSnapshot],
        canInstall: Bool,
        canRemove: Bool,
        canActivate: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.origin = origin
        self.storageState = storageState
        self.downloadSize = downloadSize
        self.languages = languages
        self.canInstall = canInstall
        self.canRemove = canRemove
        self.canActivate = canActivate
    }
}

public struct ModelManagerSnapshot: Equatable, Sendable {
    public let models: [ModelSnapshot]
    public let activeModelID: ModelID?
    public let activePreferences: ModelPreference?
    public let runtimeState: ModelRuntimeState
    public let operation: ModelOperation

    public init(
        models: [ModelSnapshot],
        activeModelID: ModelID?,
        activePreferences: ModelPreference?,
        runtimeState: ModelRuntimeState,
        operation: ModelOperation
    ) {
        self.models = models
        self.activeModelID = activeModelID
        self.activePreferences = activePreferences
        self.runtimeState = runtimeState
        self.operation = operation
    }
}

public enum ModelManagerError: Error, Equatable, Sendable {
    case unknownModel(ModelID)
    case notInstalled(ModelID)
    case speechActive
    case operationInProgress
    case bundledModelCannotBeRemoved
    case activeModelCannotBeRemoved
    case invalidVoice(String)
    case invalidLanguage(String)
    case loadFailed(ModelID, message: String)
    case noActiveModel
    case modelNotReady
}

public protocol ModelManaging: SpeechSynthesizing, Sendable {
    func snapshot() async -> ModelManagerSnapshot
    func updates() async -> AsyncStream<ModelManagerSnapshot>
    func install(_ id: ModelID) async throws
    func cancelInstallation() async
    func installLanguage(_ code: String, for id: ModelID) async throws
    func registerLocalModel(at directory: URL) async throws -> ModelID
    func remove(_ id: ModelID) async throws
    func activate(_ id: ModelID) async throws
    func updatePreferences(_ preferences: ModelPreference) async throws
    func warmConfiguredModel() async
}

public extension ModelManaging {
    func cancelInstallation() async {}
}

public actor ModelManager: ModelManaging {
    private let catalog: CuratedModelCatalog
    private let library: any ModelLibraryProtocol
    private let session: any MLXModelSession
    private let activityGate: ReadBackActivityGate
    private let configurationStore: AppConfigurationStore
    private let configurationURL: URL

    private var configuration: AppConfiguration
    private var runtimeState: ModelRuntimeState = .starting
    private var operation: ModelOperation = .idle
    private var inFlightGenerations = 0
    private var updateContinuations: [UUID: AsyncStream<ModelManagerSnapshot>.Continuation] = [:]

    public init(
        catalog: CuratedModelCatalog,
        library: any ModelLibraryProtocol,
        session: any MLXModelSession,
        activityGate: ReadBackActivityGate,
        configuration: AppConfiguration,
        configurationURL: URL,
        configurationStore: AppConfigurationStore = AppConfigurationStore()
    ) {
        self.catalog = catalog
        self.library = library
        self.session = session
        self.activityGate = activityGate
        self.configuration = configuration
        self.configurationURL = configurationURL.standardizedFileURL
        self.configurationStore = configurationStore
    }

    public func snapshot() async -> ModelManagerSnapshot {
        await makeSnapshot()
    }

    public func updates() async -> AsyncStream<ModelManagerSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModelManagerSnapshot>.makeStream()
        updateContinuations[id] = continuation
        continuation.yield(await makeSnapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func warmConfiguredModel() async {
        let preferred = configuration.activeModelID
        do {
            try await loadAndWarm(preferred)
            runtimeState = .ready(preferred)
        } catch {
            do {
                await session.unload()
                try await loadAndWarm(.kokoro)
                configuration.activeModelID = .kokoro
                ensureDefaultPreferences(for: .kokoro)
                try persistConfiguration()
                runtimeState = .ready(.kokoro)
            } catch {
                runtimeState = .failed(.kokoro, message: String(describing: error))
            }
        }
        await publish()
    }

    public func synthesize(_ request: SpeechRequest) async throws -> AudioClip {
        guard operation == .idle, case .ready(let modelID) = runtimeState else {
            throw ModelManagerError.modelNotReady
        }
        inFlightGenerations += 1
        defer { inFlightGenerations -= 1 }
        let resolved = try await resolvedRequest(request, for: modelID)
        return try await session.synthesize(resolved)
    }

    public func install(_ id: ModelID) async throws {
        try requireIdleOperation()
        operation = .installingModel(id)
        await publish()
        do {
            try await library.install(id) { [weak self] _ in
                await self?.publish()
            }
            operation = .idle
            await publish()
        } catch {
            operation = .idle
            await publish()
            throw error
        }
    }

    public func cancelInstallation() async {
        await library.cancelInstallation()
    }

    public func installLanguage(_ code: String, for id: ModelID) async throws {
        try requireIdleOperation()
        operation = .installingLanguage(modelID: id, languageCode: code)
        await publish()
        do {
            try await library.installLanguage(code, for: id)
            operation = .idle
            await publish()
        } catch {
            operation = .idle
            await publish()
            throw error
        }
    }

    public func registerLocalModel(at directory: URL) async throws -> ModelID {
        try requireIdleOperation()
        guard configuration.activeModelID != .local else {
            throw ModelManagerError.activeModelCannotBeRemoved
        }
        operation = .importingLocal
        await publish()
        do {
            try await library.registerLocalModel(at: directory)
            operation = .idle
            ensureDefaultPreferences(for: .local)
            try persistConfiguration()
            await publish()
            return .local
        } catch {
            operation = .idle
            await publish()
            throw error
        }
    }

    public func remove(_ id: ModelID) async throws {
        try requireIdleOperation()
        guard id != .kokoro else { throw ModelManagerError.bundledModelCannotBeRemoved }
        guard configuration.activeModelID != id else {
            throw ModelManagerError.activeModelCannotBeRemoved
        }
        operation = .removing(id)
        await publish()
        do {
            try await library.remove(id)
            configuration.modelPreferences.removeAll { $0.modelID == id }
            try persistConfiguration()
            operation = .idle
            await publish()
        } catch {
            operation = .idle
            await publish()
            throw error
        }
    }

    public func activate(_ id: ModelID) async throws {
        try requireIdleOperation()
        guard inFlightGenerations == 0 else { throw ModelManagerError.speechActive }
        guard id != configuration.activeModelID else { return }
        let priorID = configuration.activeModelID
        operation = .switching(from: priorID, to: id)
        runtimeState = .unloading(priorID)

        do {
            try await activityGate.beginModelSwitch()
        } catch {
            operation = .idle
            runtimeState = .ready(priorID)
            await publish()
            throw ModelManagerError.speechActive
        }
        await publish()

        do {
            _ = try await library.location(for: id)
            await session.unload()
            try await loadAndWarm(id)
            configuration.activeModelID = id
            ensureDefaultPreferences(for: id)
            try persistConfiguration()
            runtimeState = .ready(id)
            operation = .idle
            await activityGate.endModelSwitch()
            await publish()
        } catch {
            await restoreAfterFailedSwitch(priorID: priorID)
            operation = .idle
            await activityGate.endModelSwitch()
            await publish()
            throw ModelManagerError.loadFailed(id, message: String(describing: error))
        }
    }

    public func updatePreferences(_ preferences: ModelPreference) async throws {
        try await validate(preferences)
        configuration.setPreferences(preferences)
        try persistConfiguration()
        await publish()
    }

    private func restoreAfterFailedSwitch(priorID: ModelID) async {
        await session.unload()
        do {
            try await loadAndWarm(priorID)
            runtimeState = .ready(priorID)
            return
        } catch {}
        do {
            await session.unload()
            try await loadAndWarm(.kokoro)
            configuration.activeModelID = .kokoro
            ensureDefaultPreferences(for: .kokoro)
            try persistConfiguration()
            runtimeState = .ready(.kokoro)
        } catch {
            runtimeState = .failed(.kokoro, message: String(describing: error))
        }
    }

    private func loadAndWarm(_ id: ModelID) async throws {
        runtimeState = .loading(id)
        let location = try await library.location(for: id)
        let profile = try await library.runtimeProfile(for: id)
        let preferences = await normalizedPreferences(for: id)
        let definition = await controlDefinition(for: id)
        try await session.load(from: location.directoryURL, profile: profile)
        let warmRequest = SpeechRequest(
            input: "test, hello world",
            voice: runtimeVoice(voiceID: preferences.voiceID, definition: definition),
            languageCode: runtimeLanguage(
                languageCode: preferences.languageCode,
                voiceID: preferences.voiceID,
                definition: definition
            ),
            speed: preferences.synthesisSpeed,
            format: .wav
        )
        _ = try await session.synthesize(warmRequest)
    }

    private func resolvedRequest(
        _ request: SpeechRequest,
        for id: ModelID
    ) async throws -> SpeechRequest {
        let preferences = await normalizedPreferences(for: id)
        let definition = await controlDefinition(for: id)
        let voice = request.voice ?? preferences.voiceID
        return SpeechRequest(
            input: request.input,
            voice: runtimeVoice(voiceID: voice, definition: definition),
            languageCode: request.languageCode ?? runtimeLanguage(
                languageCode: preferences.languageCode,
                voiceID: voice,
                definition: definition
            ),
            speed: request.speed,
            format: request.format
        )
    }

    private func runtimeVoice(
        voiceID: String?,
        definition: CuratedModelDefinition?
    ) -> String? {
        guard let voiceID, let definition else { return voiceID }
        return definition.voices.first(where: { $0.id == voiceID })?.runtimeValue ?? voiceID
    }

    private func runtimeLanguage(
        languageCode: String?,
        voiceID: String?,
        definition: CuratedModelDefinition?
    ) -> String? {
        guard let definition else { return nil }
        let voiceLanguage = voiceID.flatMap { selectedVoiceID in
            definition.voices.first(where: { $0.id == selectedVoiceID })?
                .supportedLanguageCodes.first
        }
        let selectedLanguageCode = languageCode ?? voiceLanguage
        return selectedLanguageCode.flatMap { code in
            definition.languages.first(where: { $0.code == code })?.runtimeValue
        }
    }

    private func defaultPreferences(for id: ModelID) -> ModelPreference {
        if let saved = configuration.preferences(for: id) { return saved }
        return catalogDefaultPreferences(for: id)
    }

    private func catalogDefaultPreferences(for id: ModelID) -> ModelPreference {
        guard let model = try? catalog.model(id: id) else {
            return ModelPreference(
                modelID: id,
                voiceID: nil,
                languageCode: nil,
                synthesisSpeed: 1
            )
        }
        return ModelPreference(
            modelID: id,
            voiceID: model.defaultVoiceID,
            languageCode: model.defaultLanguageCode,
            synthesisSpeed: model.defaultSynthesisSpeed
        )
    }

    private func normalizedPreferences(for id: ModelID) async -> ModelPreference {
        guard let model = await controlDefinition(for: id) else {
            return defaultPreferences(for: id)
        }
        let fallback = ModelPreference(
            modelID: id,
            voiceID: model.defaultVoiceID,
            languageCode: model.defaultLanguageCode,
            synthesisSpeed: model.defaultSynthesisSpeed
        )
        let saved = configuration.preferences(for: id) ?? fallback
        let voice = saved.voiceID.flatMap { voiceID in
            model.voices.first { $0.id == voiceID }
        }
        let language = saved.languageCode.flatMap { code in
            model.languages.first { $0.code == code }
        }
        let voiceIsValid = saved.voiceID == nil || voice != nil
        let languageIsValid = saved.languageCode == nil || language != nil
        let pairIsValid = switch (voice, language) {
        case let (.some(voice), .some(language)):
            voice.supports(languageCode: language.code)
        default:
            true
        }
        let requiredLanguage = language ?? voice?.supportedLanguageCodes.first.flatMap { code in
            model.languages.first { $0.code == code }
        }
        let languageIsInstalled = if let requiredLanguage {
            await library.isLanguageInstalled(requiredLanguage.code, for: id)
        } else {
            true
        }
        guard voiceIsValid, languageIsValid, pairIsValid, languageIsInstalled else {
            configuration.setPreferences(fallback)
            try? persistConfiguration()
            return fallback
        }
        if configuration.preferences(for: id) == nil {
            configuration.setPreferences(saved)
            try? persistConfiguration()
        }
        return saved
    }

    private func ensureDefaultPreferences(for id: ModelID) {
        guard configuration.preferences(for: id) == nil else { return }
        configuration.setPreferences(defaultPreferences(for: id))
    }

    private func validate(_ preference: ModelPreference) async throws {
        guard let model = await controlDefinition(for: preference.modelID) else {
            if preference.modelID != .local {
                throw ModelManagerError.unknownModel(preference.modelID)
            }
            guard preference.voiceID == nil else {
                throw ModelManagerError.invalidVoice(preference.voiceID ?? "")
            }
            guard preference.languageCode == nil else {
                throw ModelManagerError.invalidLanguage(preference.languageCode ?? "")
            }
            return
        }
        if let voice = preference.voiceID,
           !model.voices.contains(where: { $0.id == voice })
        {
            throw ModelManagerError.invalidVoice(voice)
        }
        if let language = preference.languageCode,
           !model.languages.contains(where: { $0.code == language })
        {
            throw ModelManagerError.invalidLanguage(language)
        }
        if let voiceID = preference.voiceID,
           let languageCode = preference.languageCode,
           !model.voices.contains(where: {
               $0.id == voiceID && $0.supports(languageCode: languageCode)
           })
        {
            throw ModelManagerError.invalidVoice(voiceID)
        }
    }

    private func controlDefinition(for id: ModelID) async -> CuratedModelDefinition? {
        if id != .local {
            return try? catalog.model(id: id)
        }
        guard let profile = try? await library.runtimeProfile(for: .local) else {
            return nil
        }
        return switch profile {
        case .qwen3CustomVoice:
            .qwen3CustomVoice06B8Bit
        case .kokoro:
            nil
        }
    }

    private func requireIdleOperation() throws {
        guard operation == .idle else { throw ModelManagerError.operationInProgress }
    }

    private func persistConfiguration() throws {
        try configurationStore.save(configuration, at: configurationURL)
    }

    private func makeSnapshot() async -> ModelManagerSnapshot {
        var models: [ModelSnapshot] = []
        for model in catalog.models {
            let storage = await library.storageState(for: model.id)
            var languages: [ModelLanguageSnapshot] = []
            for language in model.languages {
                let installed = await library.isLanguageInstalled(language.code, for: model.id)
                languages.append(
                    ModelLanguageSnapshot(
                        code: language.code,
                        displayName: language.displayName,
                        voices: model.voices.filter {
                            $0.supports(languageCode: language.code)
                        },
                        isInstalled: installed,
                        canInstall: !installed && language.distribution == .downloadable
                    )
                )
            }
            let installed = Self.isInstalled(storage)
            let canInstall = if case .notInstalled = storage {
                model.distribution == .downloadable
            } else {
                false
            }
            models.append(
                ModelSnapshot(
                    id: model.id,
                    displayName: model.displayName,
                    origin: model.distribution == .bundled ? .bundled : .managedDownload,
                    storageState: storage,
                    downloadSize: model.distribution == .downloadable
                        ? model.downloadSize
                        : nil,
                    languages: languages,
                    canInstall: canInstall,
                    canRemove: installed
                        && model.distribution == .downloadable
                        && configuration.activeModelID != model.id,
                    canActivate: installed
                        && configuration.activeModelID != model.id
                        && operation == .idle
                )
            )
        }
        let localState = await library.storageState(for: .local)
        if localState != .notInstalled {
            let displayName = await library.displayName(for: .local) ?? "Local Model"
            let definition = await controlDefinition(for: .local)
            var languages: [ModelLanguageSnapshot] = []
            if let definition {
                for language in definition.languages {
                    languages.append(
                        ModelLanguageSnapshot(
                            code: language.code,
                            displayName: language.displayName,
                            voices: definition.voices.filter {
                                $0.supports(languageCode: language.code)
                            },
                            isInstalled: true,
                            canInstall: false
                        )
                    )
                }
            }
            models.append(
                ModelSnapshot(
                    id: .local,
                    displayName: displayName,
                    origin: .local,
                    storageState: localState,
                    downloadSize: nil,
                    languages: languages,
                    canInstall: false,
                    canRemove: configuration.activeModelID != .local,
                    canActivate: localState == .localAvailable
                        && configuration.activeModelID != .local
                        && operation == .idle
                )
            )
        }
        return ModelManagerSnapshot(
            models: models,
            activeModelID: Self.activeModelID(from: runtimeState),
            activePreferences: configuration.preferences(for: configuration.activeModelID),
            runtimeState: runtimeState,
            operation: operation
        )
    }

    private func publish() async {
        let value = await makeSnapshot()
        for continuation in updateContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    private static func isInstalled(_ state: ModelStorageState) -> Bool {
        switch state {
        case .bundled, .installed, .localAvailable: true
        default: false
        }
    }

    private static func activeModelID(from state: ModelRuntimeState) -> ModelID? {
        switch state {
        case .loading(let id), .ready(let id), .unloading(let id): id
        case .failed(let id, _): id
        case .starting: nil
        }
    }
}
