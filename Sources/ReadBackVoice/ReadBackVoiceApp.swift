import AppKit
import ReadBackCore
import ReadBackInference
import ReadBackMac
import ReadBackService
import ServiceManagement
import SwiftUI

@main
@MainActor
enum ReadBackLauncher {
    private static let instanceLock = SingleInstanceLock(
        lockFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ai.sanrin.readback.instance.lock")
    )

    static func main() {
        guard instanceLock.acquire() else {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "ai.sanrin.readback"
            ).first?.activate()
            return
        }

        ReadBackApp.main()
    }
}

struct ReadBackApp: App {
    @StateObject private var controller = ServiceController()

    var body: some Scene {
        MenuBarExtra {
            ReadBackPopover(controller: controller)
        } label: {
            Image(nsImage: BrandImages.menuBarWaveform)
                .accessibilityLabel("ReadBack")
                .task {
                    controller.launch()
                }
        }
        .menuBarExtraStyle(.window)

        Window(ModelManagerPresentation.settingsWindowTitle, id: "model-manager") {
            ModelManagerView(controller: controller)
                .frame(minWidth: 460, minHeight: 360)
        }
    }
}

@MainActor
private enum BrandImages {
    static let colorWaveform = loadPNG(
        named: "ReadBack",
        fallbackSystemName: "waveform"
    )

    static let menuBarWaveform: NSImage = {
        let image = loadPNG(
            named: "ReadBackMenuBarTemplate",
            fallbackSystemName: "waveform"
        )
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private static func loadPNG(named name: String, fallbackSystemName: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSImage(
            systemSymbolName: fallbackSystemName,
            accessibilityDescription: "ReadBack"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}

struct ReadBackPopover: View {
    @ObservedObject var controller: ServiceController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: BrandImages.colorWaveform)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Circle()
                        .fill(controller.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                        }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.isRunning ? "ReadBack running" : "ReadBack stopped")

                VStack(alignment: .leading, spacing: 1) {
                    Text("ReadBack")
                        .font(.headline)
                    Text(controller.status)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("127.0.0.1:\(controller.configuration.publicPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let shortcutStatus = controller.shortcutStatus {
                Text(shortcutStatus)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Divider()

            HStack {
                Button(controller.isRunning ? "Stop service" : "Start service") {
                    if controller.isRunning {
                        controller.stop()
                    } else {
                        controller.start()
                    }
                }
                Button(controller.clipboardActionLabel) {
                    controller.readClipboard()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Menu {
                ForEach(controller.installedModels) { model in
                    Button {
                        controller.activateModel(model.id)
                    } label: {
                        if model.id == controller.activeModelID {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
                Divider()
                Button("Manage Models…") {
                    openWindow(id: "model-manager")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } label: {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(controller.activeModelName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(!controller.canChangeModel)

            Menu {
                ForEach(controller.availableVoices) { voice in
                    Button {
                        controller.setVoice(voice)
                    } label: {
                        if voice.id == controller.selectedVoiceID {
                            Label(voice.displayName, systemImage: "checkmark")
                        } else {
                            Text(voice.displayName)
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Voice")
                    Spacer()
                    Text(controller.selectedVoiceName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(controller.availableVoices.isEmpty || !controller.canChangeVoice)

            Menu {
                ForEach(controller.activeLanguages) { language in
                    if language.isInstalled {
                        Button {
                            controller.selectLanguage(language)
                        } label: {
                            if language.code == controller.selectedLanguageCode {
                                Label(language.displayName, systemImage: "checkmark")
                            } else {
                                Text(language.displayName)
                            }
                        }
                    } else {
                        Button {
                            controller.installLanguage(language)
                        } label: {
                            Label(
                                controller.installingLanguageID == language.code
                                    ? "Installing \(language.displayName)…"
                                    : "Install \(language.displayName)",
                                systemImage: "arrow.down.circle"
                            )
                        }
                        .disabled(controller.installingLanguageID != nil || !language.canInstall)
                    }
                }
            } label: {
                HStack {
                    Text("Languages")
                    Spacer()
                    Text(controller.selectedLanguageName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Paragraph Pause")
                    Spacer()
                    Text(ServiceController.paragraphPauseLabel(controller.paragraphPause))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { controller.paragraphPause },
                        set: { controller.setParagraphPause($0) }
                    ),
                    in: ParagraphPause.minimum...ParagraphPause.maximum,
                    step: ParagraphPause.step
                )
                .accessibilityLabel("Paragraph Pause")
                .accessibilityValue(
                    ServiceController.paragraphPauseLabel(controller.paragraphPause)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Playback Speed")
                    Spacer()
                    Text(ServiceController.playbackRateLabel(controller.playbackRate))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { controller.playbackRate },
                        set: { controller.setPlaybackRate($0) }
                    ),
                    in: PlaybackRate.minimum...PlaybackRate.maximum,
                    step: PlaybackRate.step
                )
                .accessibilityLabel("Playback Speed")
                .accessibilityValue(
                    ServiceController.playbackRateLabel(controller.playbackRate)
                )
            }

            Divider()

            HStack {
                Label(
                    controller.modelInstalled
                        ? "\(controller.activeModelName) ready"
                        : "Model unavailable",
                    systemImage: controller.modelInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(controller.modelInstalled ? Color.secondary : Color.orange)
                Spacer()
                Button(ModelManagerPresentation.settingsButtonTitle) {
                    openWindow(id: "model-manager")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Button("Quit") {
                    Task { await controller.quit() }
                }
            }

            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .disabled(!controller.canManageLaunchAtLogin)
        }
        .padding(14)
        .frame(width: 340)
    }
}

@MainActor
final class ServiceController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var status = "Starting…"
    @Published private(set) var launchAtLogin = false
    @Published private(set) var shortcutStatus: String?
    @Published private(set) var clipboardPlaybackState: ClipboardPlaybackState = .idle
    @Published private(set) var playbackRate = PlaybackRate.default
    @Published private(set) var paragraphPause = ParagraphPause.default
    @Published var selectedVoiceID: String? = "af_heart"
    @Published var installingLanguageID: String?
    @Published var modelSnapshot = ModelManagerSnapshot(
        models: [],
        activeModelID: nil,
        activePreferences: nil,
        runtimeState: .starting,
        operation: .idle
    )

    var clipboardActionLabel: String {
        switch clipboardPlaybackState {
        case .idle: "Read Clipboard (⌥⌘R)"
        case .starting: "Cancel Read-Back (⌥⌘R)"
        case .playing: "Pause Read-Back (⌥⌘R)"
        case .paused: "Resume Read-Back (⌥⌘R)"
        }
    }

    var configuration: AppConfiguration
    let canManageLaunchAtLogin: Bool

    private let paths: RuntimePaths
    let modelManager: any ModelManaging
    private let api: ReadBackAPI
    private let player: AVFoundationAudioPlayer
    private let modelWarmup: BackgroundModelWarmup
    private let clipboardSpeaker: VoicePipeTextSpeaker
    private let clipboardAction: ClipboardReadBackAction
    private let speechSettings: SpeechSettingsStore
    private var serviceTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var clipboardRequestID: UUID?
    private var pendingClipboardStartID: UUID?
    private var currentClipboardText: String?
    private var hotKey: GlobalHotKey?

    init() {
        paths = RuntimePaths.resolve()
        let developmentModel = paths.modelsDirectory.appendingPathComponent(
            ModelDescriptor.kokoro.directoryName,
            isDirectory: true
        )
        let resources = Bundle.main.resourceURL ?? paths.supportDirectory
        let assets = ModelAssetLocations.resolve(
            bundleResourcesURL: resources,
            supportDirectory: paths.supportDirectory,
            developmentModelsURL: FileManager.default.fileExists(atPath: developmentModel.path)
                ? developmentModel
                : nil
        )
        let modelWorkspace = ModelWorkspace(
            bundledModelURL: assets.bundledModelURL,
            installedLanguagesURL: assets.installedLanguagesURL,
            runtimeModelURL: assets.runtimeModelURL
        )
        _ = try? modelWorkspace.prepare()
        let loadedConfiguration: AppConfiguration
        do {
            loadedConfiguration = try AppConfigurationStore().loadOrCreate(
                at: paths.configurationFile,
                modelsDirectory: assets.runtimeModelURL.deletingLastPathComponent()
            )
        } catch {
            loadedConfiguration = .default(
                modelDirectory: assets.runtimeModelURL.deletingLastPathComponent()
            )
        }
        configuration = loadedConfiguration
        configuration.modelDirectory = assets.runtimeModelURL.deletingLastPathComponent()
        try? AppConfigurationStore().save(configuration, at: paths.configurationFile)
        playbackRate = configuration.playbackRate
        paragraphPause = configuration.paragraphPause
        selectedVoiceID = configuration.preferences(for: configuration.activeModelID)?.voiceID

        let catalog = CuratedModelCatalog.bundled
        let managedModelsURL = paths.supportDirectory.appendingPathComponent(
            "Models",
            isDirectory: true
        )
        let session = MLXSpeechModelSession(
            languageResourceRoots: [
                assets.bundledLanguagesURL,
                assets.installedLanguagesURL,
                managedModelsURL
                    .appendingPathComponent(ModelID.kokoro.rawValue, isDirectory: true)
                    .appendingPathComponent(CuratedModelDefinition.kokoro.revision, isDirectory: true)
                    .appendingPathComponent("Languages", isDirectory: true),
            ]
        )
        let library = ModelLibrary(
            catalog: catalog,
            paths: ModelLibraryPaths(
                managedModelsURL: managedModelsURL,
                downloadsURL: paths.supportDirectory.appendingPathComponent(
                    "Downloads",
                    isDirectory: true
                ),
                localRegistrationURL: paths.supportDirectory.appendingPathComponent(
                    "local-model.json"
                )
            ),
            bundledModels: [.kokoro: assets.runtimeModelURL],
            validator: session
        )
        let activityGate = ReadBackActivityGate()
        let manager = ModelManager(
            catalog: catalog,
            library: library,
            session: session,
            activityGate: activityGate,
            configuration: configuration,
            configurationURL: paths.configurationFile
        )
        modelManager = manager
        modelWarmup = BackgroundModelWarmup {
            await manager.warmConfiguredModel()
        }
        let audioPlayer = AVFoundationAudioPlayer()
        audioPlayer.setPlaybackRate(configuration.playbackRate)
        player = audioPlayer
        let coordinator = SpeechCoordinator(
            synthesizer: manager,
            player: audioPlayer,
            activityGate: activityGate
        )
        let settings = SpeechSettingsStore(configuration: configuration)
        speechSettings = settings
        api = ReadBackAPI(
            configuration: configuration,
            modelManager: manager,
            coordinator: coordinator,
            speechSettings: settings
        )
        let clipboardEndpoint = URL(
            string: "ws://\(configuration.publicHost):\(configuration.publicPort)/v1/readback/stream"
        )!
        clipboardSpeaker = VoicePipeTextSpeaker(endpoint: clipboardEndpoint)
        clipboardAction = ClipboardReadBackAction(
            speaker: clipboardSpeaker,
            maximumCharacters: 2_000
        )
        canManageLaunchAtLogin = Bundle.main.bundleURL.pathExtension == "app"
        launchAtLogin = canManageLaunchAtLogin && SMAppService.mainApp.status == .enabled

        let shortcut = GlobalHotKey()
        hotKey = shortcut
        do {
            try shortcut.registerReadClipboard { [weak self] in
                self?.readClipboard()
            }
        } catch {
            shortcutStatus = "⌥⌘R unavailable: \(error.localizedDescription)"
        }

        Task {
            await observeModelUpdates()
        }
    }

    func launch() {
        start()
        Task { [modelWarmup] in
            await modelWarmup.start()
        }
    }

    func start() {
        guard serviceTask == nil else { return }
        status = "Starting service…"
        serviceTask = Task { [api] in
            do {
                isRunning = true
                status = "Loading model…"
                try await api.run()
            } catch is CancellationError {
            } catch {
                isRunning = false
                serviceTask = nil
                status = "Service error: \(error)"
            }
        }
    }

    func stop() {
        let requestID = clipboardRequestID
        clipboardTask?.cancel()
        clipboardTask = nil
        clipboardRequestID = nil
        pendingClipboardStartID = nil
        currentClipboardText = nil
        clipboardPlaybackState = .idle
        if let requestID {
            Task { await clipboardSpeaker.cancel(requestID: requestID) }
        }
        serviceTask?.cancel()
        serviceTask = nil
        isRunning = false
        status = "Stopped"
    }

    func quit() async {
        let requestID = clipboardRequestID
        clipboardTask?.cancel()
        clipboardTask = nil
        clipboardRequestID = nil
        pendingClipboardStartID = nil
        currentClipboardText = nil
        clipboardPlaybackState = .idle
        if let requestID {
            await clipboardSpeaker.cancel(requestID: requestID)
        }
        serviceTask?.cancel()
        serviceTask = nil
        await modelWarmup.cancel()
        NSApplication.shared.terminate(nil)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard canManageLaunchAtLogin else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            status = "Login setting failed: \(error)"
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let normalized = PlaybackRate.clamped(rate)
        guard normalized != playbackRate else { return }

        configuration.setPlaybackRate(normalized)
        playbackRate = normalized
        player.setPlaybackRate(normalized)
        do {
            try AppConfigurationStore().save(configuration, at: paths.configurationFile)
            status = "Playback speed: \(Self.playbackRateLabel(normalized))"
        } catch {
            status = "Playback speed changed but could not be saved: \(error.localizedDescription)"
        }
    }

    func setParagraphPause(_ seconds: Double) {
        let normalized = ParagraphPause.clamped(seconds)
        guard normalized != paragraphPause else { return }

        configuration.setParagraphPause(normalized)
        paragraphPause = normalized
        saveSpeechConfiguration(
            status: "Paragraph pause: \(Self.paragraphPauseLabel(normalized))"
        )
        refreshSpeechSettingsAndRestartIfNeeded()
    }

    static func playbackRateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    static func paragraphPauseLabel(_ seconds: Double) -> String {
        "\(Int((seconds * 1_000).rounded())) ms"
    }

    func readClipboard() {
        let text: String
        do {
            text = try clipboardAction.validatedText(from: SystemClipboardReader.readText())
        } catch ClipboardReadBackError.noText {
            status = "Clipboard has no text"
            return
        } catch ClipboardReadBackError.tooLong(let actual, let maximum) {
            status = "Clipboard is too long (\(actual)/\(maximum) characters)"
            return
        } catch {
            status = "Could not read the clipboard: \(error)"
            return
        }

        let command = ClipboardPlaybackDecision.command(
            state: clipboardPlaybackState,
            currentText: currentClipboardText,
            clipboardText: text
        )
        switch command {
        case .start(let text), .replace(let text):
            startClipboardSpeech(text)
        case .cancelStarting:
            cancelPendingClipboardSpeech()
        case .pause:
            pauseClipboardSpeech()
        case .resume:
            resumeClipboardSpeech()
        }
    }

    func startClipboardSpeech(
        _ text: String,
        completionStatus: String? = nil
    ) {
        let previousRequestID = clipboardRequestID
        let requestID = UUID()
        clipboardTask?.cancel()
        clipboardRequestID = requestID
        pendingClipboardStartID = requestID
        currentClipboardText = text
        clipboardPlaybackState = .starting
        status = "Preparing clipboard speech…"

        clipboardTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                if let previousRequestID {
                    await clipboardSpeaker.cancel(requestID: previousRequestID)
                }
                try Task.checkCancellation()
                guard modelInstalled else {
                    throw ServiceControllerError.modelNotInstalled
                }
                await speechSettings.update(SpeechSettings(configuration: configuration))
                if serviceTask == nil {
                    start()
                }
                try await waitForPublicService()
                try Task.checkCancellation()
                guard clipboardRequestID == requestID else { return }
                try await clipboardSpeaker.speak(text, requestID: requestID) { [weak self] in
                    await self?.clipboardSpeechDidStart(requestID: requestID)
                }
                guard clipboardRequestID == requestID else {
                    return
                }
                finishClipboardRequest(
                    requestID: requestID,
                    status: completionStatus ?? "Ready — read \(text.count) characters"
                )
            } catch is CancellationError {
            } catch ServiceControllerError.modelNotInstalled {
                if clipboardRequestID == requestID {
                    finishClipboardRequest(
                        requestID: requestID,
                        status: "The active model is unavailable"
                    )
                }
            } catch {
                if clipboardRequestID == requestID {
                    finishClipboardRequest(
                        requestID: requestID,
                        status: "Clipboard read-back failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func cancelPendingClipboardSpeech() {
        guard let requestID = clipboardRequestID else { return }
        clipboardTask?.cancel()
        pendingClipboardStartID = nil
        clipboardPlaybackState = .starting
        status = "Cancelling read-back…"
        clipboardTask = Task { [weak self, clipboardSpeaker] in
            await clipboardSpeaker.cancel(requestID: requestID)
            guard let self, clipboardRequestID == requestID else { return }
            finishClipboardRequest(requestID: requestID, status: "Read-back cancelled")
        }
    }

    private func pauseClipboardSpeech() {
        let requestID = clipboardRequestID
        guard let requestID else { return }
        Task {
            do {
                if try await clipboardSpeaker.pause(requestID: requestID),
                   clipboardRequestID == requestID
                {
                    clipboardPlaybackState = .paused
                    status = "Read-back paused"
                }
            } catch {
                if clipboardRequestID == requestID {
                    status = "Could not pause read-back: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resumeClipboardSpeech() {
        let requestID = clipboardRequestID
        guard let requestID else { return }
        Task {
            do {
                if try await clipboardSpeaker.resume(requestID: requestID),
                   clipboardRequestID == requestID
                {
                    clipboardPlaybackState = .playing
                    status = "Reading clipboard…"
                }
            } catch {
                if clipboardRequestID == requestID {
                    status = "Could not resume read-back: \(error.localizedDescription)"
                }
            }
        }
    }

    private func clipboardSpeechDidStart(requestID: UUID) {
        guard clipboardRequestID == requestID,
              pendingClipboardStartID == requestID,
              !Task.isCancelled
        else { return }
        pendingClipboardStartID = nil
        clipboardPlaybackState = .playing
        status = "Reading clipboard…"
    }

    private func finishClipboardRequest(requestID: UUID, status: String) {
        guard clipboardRequestID == requestID else { return }
        clipboardTask = nil
        clipboardRequestID = nil
        pendingClipboardStartID = nil
        currentClipboardText = nil
        clipboardPlaybackState = .idle
        self.status = status
    }

    private func saveSpeechConfiguration(status successStatus: String) {
        do {
            try AppConfigurationStore().save(configuration, at: paths.configurationFile)
            status = successStatus
        } catch {
            status = "Setting changed but could not be saved: \(error.localizedDescription)"
        }
    }

    private func refreshSpeechSettingsAndRestartIfNeeded() {
        let activeText = currentClipboardText
        Task { [weak self, speechSettings] in
            guard let self else { return }
            await speechSettings.update(SpeechSettings(configuration: configuration))
            if let activeText, currentClipboardText == activeText {
                startClipboardSpeech(activeText)
            }
        }
    }

    private func waitForPublicService() async throws {
        let healthURL = URL(
            string: "http://\(configuration.publicHost):\(configuration.publicPort)/health"
        )!
        for _ in 0..<300 {
            if let (data, response) = try? await URLSession.shared.data(from: healthURL),
               let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode),
               let health = try? JSONDecoder().decode(LocalServiceHealth.self, from: data),
               health.isReadyForSpeech
            {
                return
            }
            let clock = ContinuousClock()
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(100)))
        }
        throw ServiceControllerError.publicServiceDidNotStart
    }

}

enum ServiceControllerError: LocalizedError {
    case modelNotInstalled
    case publicServiceDidNotStart

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            "The Kokoro model is not installed."
        case .publicServiceDidNotStart:
            "The local read-back service did not become ready."
        }
    }
}
