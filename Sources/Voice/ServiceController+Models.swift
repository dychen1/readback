import AppKit
import ReadBackCore

@MainActor
extension ServiceController {
    var modelPresentation: ModelManagerPresentation {
        ModelManagerPresentation(snapshot: modelSnapshot)
    }

    var installedModels: [ModelSnapshot] { modelPresentation.installed }
    var availableModels: [ModelSnapshot] { modelPresentation.available }
    var activeModelID: ModelID? { modelSnapshot.activeModelID }
    var activeModelName: String { modelPresentation.activeModel?.displayName ?? "None" }
    var activeLanguages: [ModelLanguageSnapshot] {
        modelPresentation.activeModel?.languages ?? []
    }
    var selectedLanguageCode: String? { modelSnapshot.activePreferences?.languageCode }
    var availableVoices: [ModelVoiceDefinition] {
        modelPresentation.activeVoices(for: selectedLanguageCode)
    }
    var selectedLanguageName: String {
        guard let selectedLanguageCode else {
            return activeLanguages.isEmpty ? "Automatic" : "Choose"
        }
        return activeLanguages.first { $0.code == selectedLanguageCode }?.displayName
            ?? "Automatic"
    }

    var selectedVoiceName: String {
        guard let selectedVoiceID else { return "Default" }
        return availableVoices.first { $0.id == selectedVoiceID }?.displayName
            ?? selectedVoiceID
    }

    var modelInstalled: Bool {
        guard let active = modelPresentation.activeModel else { return false }
        switch active.storageState {
        case .bundled, .installed, .localAvailable:
            return true
        default:
            return false
        }
    }

    var canChangeModel: Bool {
        clipboardPlaybackState == .idle && modelSnapshot.operation == .idle
    }

    var canChangeVoice: Bool {
        canChangeModel && modelInstalled && !modelPresentation.isChangingModel
    }

    func observeModelUpdates() async {
        let updates = await modelManager.updates()
        for await snapshot in updates {
            if snapshot.activeModelID != modelSnapshot.activeModelID
                || snapshot.activePreferences != modelSnapshot.activePreferences
            {
                await coordinator.invalidateReplayCache()
            }
            modelSnapshot = snapshot
            if let activeID = snapshot.activeModelID {
                configuration.activeModelID = activeID
            }
            if let preference = snapshot.activePreferences {
                configuration.setPreferences(preference)
                selectedVoiceID = preference.voiceID
            }
            updateStatus(for: snapshot)
        }
    }

    func activateModel(_ id: ModelID) {
        guard canChangeModel, id != activeModelID else { return }
        status = "Switching model…"
        Task {
            do {
                try await modelManager.activate(id)
            } catch {
                status = "Could not switch model: \(error.localizedDescription)"
            }
        }
    }

    func setVoice(_ voice: ModelVoiceDefinition) {
        guard canChangeVoice, let activeModelID else { return }
        let current = modelSnapshot.activePreferences
        let languageCode = current?.languageCode.flatMap { currentLanguage in
            voice.supports(languageCode: currentLanguage) ? currentLanguage : nil
        } ?? voice.supportedLanguageCodes.first
        let preference = ModelPreference(
            modelID: activeModelID,
            voiceID: voice.id,
            languageCode: languageCode,
            synthesisSpeed: current?.synthesisSpeed ?? 1
        )
        Task {
            do {
                try await modelManager.updatePreferences(preference)
                selectedVoiceID = voice.id
                status = "Voice: \(voice.displayName)"
                startClipboardSpeech(
                    "test, hello world",
                    completionStatus: "Voice preview finished"
                )
            } catch {
                status = "Could not select voice: \(error.localizedDescription)"
            }
        }
    }

    func selectLanguage(_ language: ModelLanguageSnapshot) {
        guard language.isInstalled,
              canChangeVoice,
              let activeModelID
        else { return }
        let current = modelSnapshot.activePreferences
        let currentVoice = language.voices.first { $0.id == current?.voiceID }
        let voice = currentVoice ?? language.voices.first
        let preference = ModelPreference(
            modelID: activeModelID,
            voiceID: voice?.id,
            languageCode: language.code,
            synthesisSpeed: current?.synthesisSpeed ?? 1
        )
        Task {
            do {
                try await modelManager.updatePreferences(preference)
                selectedVoiceID = voice?.id
                status = "Language: \(language.displayName)"
                startClipboardSpeech(
                    "test, hello world",
                    completionStatus: "Language preview finished"
                )
            } catch {
                status = "Could not select language: \(error.localizedDescription)"
            }
        }
    }

    func installModel(_ model: ModelSnapshot) {
        guard model.canInstall, modelSnapshot.operation == .idle else { return }
        status = "Installing \(model.displayName)…"
        Task {
            do {
                try await modelManager.install(model.id)
                status = "\(model.displayName) installed"
            } catch {
                status = "Could not install \(model.displayName): \(error.localizedDescription)"
            }
        }
    }

    func cancelModelInstallation() {
        status = "Cancelling download…"
        Task {
            await modelManager.cancelInstallation()
        }
    }

    func installLanguage(_ language: ModelLanguageSnapshot) {
        guard let activeModelID,
              language.canInstall,
              installingLanguageID == nil
        else { return }
        installingLanguageID = language.code
        status = "Installing \(language.displayName)…"
        Task {
            defer { installingLanguageID = nil }
            do {
                try await modelManager.installLanguage(language.code, for: activeModelID)
                status = "\(language.displayName) installed"
            } catch {
                status = "Could not install \(language.displayName): \(error.localizedDescription)"
            }
        }
    }

    func chooseLocalModel() {
        guard canChangeModel else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an MLX speech model"
        panel.prompt = "Use Model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        status = "Checking local model…"
        Task {
            do {
                _ = try await modelManager.registerLocalModel(at: directory)
                status = "Local model added"
            } catch {
                status = "Could not add local model: \(error.localizedDescription)"
            }
        }
    }

    func removeModel(_ model: ModelSnapshot) {
        guard model.canRemove else { return }
        Task {
            do {
                try await modelManager.remove(model.id)
                status = "\(model.displayName) removed"
            } catch {
                status = "Could not remove \(model.displayName): \(error.localizedDescription)"
            }
        }
    }

    private func updateStatus(for snapshot: ModelManagerSnapshot) {
        switch snapshot.runtimeState {
        case .starting:
            status = "Starting…"
        case .loading(let id):
            status = "Loading \(modelName(id))…"
        case .unloading:
            status = "Switching model…"
        case .ready:
            if snapshot.operation == .idle, clipboardPlaybackState == .idle {
                status = "Ready"
            }
        case .failed(_, let message):
            status = "Model failed: \(message)"
        }
    }

    private func modelName(_ id: ModelID) -> String {
        modelSnapshot.models.first { $0.id == id }?.displayName ?? id.rawValue
    }
}
