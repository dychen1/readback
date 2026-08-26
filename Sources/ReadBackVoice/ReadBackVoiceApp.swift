import AppKit
import ReadBackCore
import ReadBackMac
import ReadBackService
import ServiceManagement
import SwiftUI

@main
struct ReadBackApp: App {
    @StateObject private var controller = ServiceController()

    var body: some Scene {
        MenuBarExtra("ReadBack", systemImage: controller.isRunning ? "waveform.circle.fill" : "waveform.circle") {
            ReadBackPopover(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ReadBackPopover: View {
    @ObservedObject var controller: ServiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: controller.isRunning ? "waveform.circle.fill" : "waveform.circle")
                    .font(.title2)
                    .foregroundStyle(controller.isRunning ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.status)
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
                Button(controller.modelInstalled ? "Reload Kokoro" : "Download Kokoro") {
                    controller.installOrLoadModel()
                }
                .disabled(controller.isBusy)

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
    private let store: ModelStore
    private let backend: MLXBackendClient
    private let supervisor: BackendSupervisor
    private let downloader = HuggingFaceModelDownloader()
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
        do {
            configuration = try AppConfigurationStore().loadOrCreate(
                at: paths.configurationFile,
                modelsDirectory: paths.modelsDirectory
            )
        } catch {
            configuration = .default(modelDirectory: paths.modelsDirectory)
        }
        playbackRate = configuration.playbackRate
        paragraphPause = configuration.paragraphPause
        selectedVoiceID = configuration.defaultVoice
        let modelPath = configuration.modelDirectory.appendingPathComponent(
            configuration.model.directoryName,
            isDirectory: true
        )
        voiceGroups = KokoroVoiceCatalog.availableGroups(in: modelPath)

        store = ModelStore(
            rootURL: configuration.modelDirectory,
            supportedModels: [configuration.model]
        )
        backend = MLXBackendClient(
            baseURL: URL(
                string: "http://\(configuration.backendHost):\(configuration.backendPort)"
            )!
        )
        supervisor = BackendSupervisor(
            command: .mlxAudio(port: configuration.backendPort),
            logURL: paths.backendLog
        )
        let audioPlayer = AVFoundationAudioPlayer()
        audioPlayer.setPlaybackRate(configuration.playbackRate)
        player = audioPlayer
        let coordinator = SpeechCoordinator(
            synthesizer: backend,
            player: audioPlayer,
            modelPath: modelPath
        )
        let settings = SpeechSettingsStore(configuration: configuration)
        speechSettings = settings
        api = ReadBackAPI(
            configuration: configuration,
            modelStore: store,
            backend: backend,
            coordinator: coordinator,
            downloader: downloader,
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
            start()
        }
    }

    func start() {
        guard serviceTask == nil else { return }
        status = "Starting service…"
        serviceTask = Task { [api, supervisor] in
            do {
                try await supervisor.start()
                isRunning = true
                status = modelInstalled ? "Ready" : "Service running; model not installed"
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
        Task { await supervisor.stop() }
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
        await supervisor.stop()
        NSApplication.shared.terminate(nil)
    }

    func installOrLoadModel() {
        guard !isBusy else { return }
        isBusy = true
        status = modelInstalled ? "Loading Kokoro…" : "Downloading Kokoro…"
        Task {
            do {
                let directory = try await store.directoryURL(for: configuration.model.id)
                if !modelInstalled {
                    try await downloader.download(configuration.model, to: directory)
                }
                await refreshModelState()
                await prepareInstalledModel()
            } catch {
                status = "Model setup failed: \(error)"
            }
            isBusy = false
        }
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
                        status: "Download Kokoro before reading the clipboard"
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

    private func waitForBackend() async throws {
        for _ in 0..<120 {
            if await backend.isHealthy() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ServiceControllerError.backendDidNotStart
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
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServiceControllerError.publicServiceDidNotStart
    }

    private func prepareInstalledModel() async {
        status = "Warming Kokoro…"
        do {
            let directory = try await store.directoryURL(for: configuration.model.id)
            try await waitForBackend()
            try await backend.loadModel(at: directory)
            _ = try await backend.synthesize(
                SpeechRequest(
                    input: "Ready.",
                    voice: configuration.defaultVoice,
                    languageCode: SpeechSettings(configuration: configuration).languageCode,
                    speed: configuration.defaultSpeed,
                    format: .wav
                ),
                modelPath: directory
            )
            status = "Ready"
        } catch {
            status = "Warm-up failed: \(error)"
        }
    }
}

enum ServiceControllerError: LocalizedError {
    case backendDidNotStart
    case modelNotInstalled
    case publicServiceDidNotStart

    var errorDescription: String? {
        switch self {
        case .backendDidNotStart:
            "The MLX backend did not start."
        case .modelNotInstalled:
            "The Kokoro model is not installed."
        case .publicServiceDidNotStart:
            "The local read-back service did not become ready."
        }
    }
}
