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
        }
        .menuBarExtraStyle(.window)
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

private struct ReadBackPopover: View {
    @ObservedObject var controller: ServiceController

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
                ForEach(controller.voiceGroups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.voices) { voice in
                            Button {
                                controller.setVoice(voice)
                            } label: {
                                if voice.id == controller.selectedVoiceID {
                                    Label(voice.name, systemImage: "checkmark")
                                } else {
                                    Text(voice.name)
                                }
                            }
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
            .disabled(controller.voiceGroups.isEmpty)

            Menu {
                ForEach(KokoroLanguagePackCatalog.all) { pack in
                    if controller.isLanguageInstalled(pack) {
                        Label(pack.name, systemImage: "checkmark")
                    } else {
                        Button {
                            controller.installLanguage(pack)
                        } label: {
                            Label(
                                controller.installingLanguageID == pack.id
                                    ? "Installing \(pack.name)…"
                                    : "Install \(pack.name)",
                                systemImage: "arrow.down.circle"
                            )
                        }
                        .disabled(controller.installingLanguageID != nil)
                    }
                }
            } label: {
                HStack {
                    Text("Languages")
                    Spacer()
                    Text("\(controller.installedLanguageIDs.count) installed")
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
                    controller.modelInstalled ? "Kokoro ready" : "Kokoro unavailable",
                    systemImage: controller.modelInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(controller.modelInstalled ? Color.secondary : Color.orange)
                Spacer()
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
    @Published private(set) var isBusy = false
    @Published private(set) var modelInstalled = false
    @Published private(set) var status = "Starting…"
    @Published private(set) var launchAtLogin = false
    @Published private(set) var shortcutStatus: String?
    @Published private(set) var clipboardPlaybackState: ClipboardPlaybackState = .idle
    @Published private(set) var playbackRate = PlaybackRate.default
    @Published private(set) var paragraphPause = ParagraphPause.default
    @Published private(set) var selectedVoiceID = "af_heart"
    @Published private(set) var voiceGroups: [KokoroVoiceGroup] = []
    @Published private(set) var installedLanguageIDs = Set<String>()
    @Published private(set) var installingLanguageID: String?

    var selectedVoiceName: String {
        KokoroVoiceCatalog.voice(id: selectedVoiceID)?.name ?? selectedVoiceID
    }

    var clipboardActionLabel: String {
        switch clipboardPlaybackState {
        case .idle: "Read Clipboard (⌥⌘R)"
        case .starting: "Cancel Read-Back (⌥⌘R)"
        case .playing: "Pause Read-Back (⌥⌘R)"
        case .paused: "Resume Read-Back (⌥⌘R)"
        }
    }

    private(set) var configuration: AppConfiguration
    let canManageLaunchAtLogin: Bool

    private let paths: RuntimePaths
    private let assets: ModelAssetLocations
    private let workspace: ModelWorkspace
    private let languagePackStore: LanguagePackStore
    private let store: ModelStore
    private let runtime: KokoroSpeechSynthesizer
    private let api: ReadBackAPI
    private let player: AVFoundationAudioPlayer
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
        self.assets = assets
        let modelWorkspace = ModelWorkspace(
            bundledModelURL: assets.bundledModelURL,
            installedLanguagesURL: assets.installedLanguagesURL,
            runtimeModelURL: assets.runtimeModelURL
        )
        workspace = modelWorkspace
        _ = try? modelWorkspace.prepare()
        languagePackStore = LanguagePackStore(rootURL: assets.installedLanguagesURL)
        do {
            configuration = try AppConfigurationStore().loadOrCreate(
                at: paths.configurationFile,
                modelsDirectory: assets.runtimeModelURL.deletingLastPathComponent()
            )
        } catch {
            configuration = .default(
                modelDirectory: assets.runtimeModelURL.deletingLastPathComponent()
            )
        }
        configuration.modelDirectory = assets.runtimeModelURL.deletingLastPathComponent()
        try? AppConfigurationStore().save(configuration, at: paths.configurationFile)
        playbackRate = configuration.playbackRate
        paragraphPause = configuration.paragraphPause
        let configuredVoiceID = configuration.defaultVoice
        selectedVoiceID = configuredVoiceID
        let modelPath = configuration.modelDirectory.appendingPathComponent(
            configuration.model.directoryName,
            isDirectory: true
        )
        let groups = KokoroVoiceCatalog.availableGroups(in: modelPath)
        voiceGroups = groups
        if !groups.contains(where: { group in
            group.voices.contains { $0.id == configuredVoiceID }
        }), let fallback = groups.first?.voices.first {
            configuration.setDefaultVoice(fallback.id)
            selectedVoiceID = fallback.id
            try? AppConfigurationStore().save(configuration, at: paths.configurationFile)
        }

        store = ModelStore(
            rootURL: configuration.modelDirectory,
            supportedModels: [configuration.model]
        )
        let speechRuntime = KokoroSpeechSynthesizer(
            modelDirectoryURL: modelPath,
            languageResourceRoots: [
                assets.bundledLanguagesURL,
                assets.installedLanguagesURL,
            ]
        )
        runtime = speechRuntime
        let audioPlayer = AVFoundationAudioPlayer()
        audioPlayer.setPlaybackRate(configuration.playbackRate)
        player = audioPlayer
        let coordinator = SpeechCoordinator(
            synthesizer: speechRuntime,
            player: audioPlayer
        )
        let settings = SpeechSettingsStore(configuration: configuration)
        speechSettings = settings
        api = ReadBackAPI(
            configuration: configuration,
            modelStore: store,
            runtime: speechRuntime,
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
            await refreshModelState()
            await refreshLanguageState()
            start()
        }
    }

    func start() {
        guard serviceTask == nil else { return }
        status = "Starting service…"
        serviceTask = Task { [api] in
            do {
                isRunning = true
                status = modelInstalled ? "Loading Kokoro…" : "Kokoro unavailable"
                if modelInstalled {
                    Task { await prepareInstalledModel() }
                }
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

    func setVoice(_ voice: KokoroVoice) {
        guard voiceGroups.contains(where: { $0.voices.contains(voice) }) else { return }

        if voice.id != selectedVoiceID {
            configuration.setDefaultVoice(voice.id)
            selectedVoiceID = voice.id
            saveSpeechConfiguration(status: "Voice: \(voice.name)")
        }
        startClipboardSpeech("test, hello world", completionStatus: "Voice preview finished")
    }

    func isLanguageInstalled(_ pack: KokoroLanguagePack) -> Bool {
        installedLanguageIDs.contains(pack.id)
    }

    func installLanguage(_ pack: KokoroLanguagePack) {
        guard !pack.isBundled, installingLanguageID == nil else { return }
        installingLanguageID = pack.id
        status = "Installing \(pack.name)…"
        Task {
            do {
                try await languagePackStore.install(packID: pack.id)
                try workspace.prepare()
                await refreshModelState()
                await refreshLanguageState()
                status = "\(pack.name) installed"
            } catch {
                status = "Could not install \(pack.name): \(error.localizedDescription)"
            }
            installingLanguageID = nil
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

    private func startClipboardSpeech(
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
                        status: "The bundled Kokoro model is unavailable"
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

    private func refreshModelState() async {
        modelInstalled = (try? await store.installedModels().contains {
            $0.descriptor.id == configuration.model.id
        }) ?? false
        let modelPath = configuration.modelDirectory.appendingPathComponent(
            configuration.model.directoryName,
            isDirectory: true
        )
        voiceGroups = KokoroVoiceCatalog.availableGroups(in: modelPath)
    }

    private func refreshLanguageState() async {
        var installed = Set<String>()
        for pack in KokoroLanguagePackCatalog.all {
            if await languagePackStore.isInstalled(pack) {
                installed.insert(pack.id)
            }
        }
        installedLanguageIDs = installed
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

    private func prepareInstalledModel() async {
        status = "Warming Kokoro…"
        do {
            try await runtime.prepare()
            _ = try await runtime.synthesize(
                SpeechRequest(
                    input: "Ready.",
                    voice: configuration.defaultVoice,
                    languageCode: SpeechSettings(configuration: configuration).languageCode,
                    speed: configuration.defaultSpeed,
                    format: .wav
                )
            )
            status = "Ready"
        } catch {
            status = "Warm-up failed: \(error)"
        }
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
