import AppKit
import ReadBackCore
import ReadBackMac
import ReadBackService
import ServiceManagement
import SwiftUI

@main
struct ReadBackVoiceApp: App {
    @StateObject private var controller = ServiceController()

    var body: some Scene {
        MenuBarExtra("ReadBack Voice", systemImage: controller.isRunning ? "waveform.circle.fill" : "waveform.circle") {
            Text(controller.status)
            Text("127.0.0.1:\(controller.configuration.publicPort)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let shortcutStatus = controller.shortcutStatus {
                Text(shortcutStatus)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()

            if controller.isRunning {
                Button("Stop service") { controller.stop() }
            } else {
                Button("Start service") { controller.start() }
            }

            Button(controller.clipboardActionLabel) {
                controller.readClipboard()
            }

            Picker(
                "Playback Speed",
                selection: Binding(
                    get: { controller.playbackRate },
                    set: { controller.setPlaybackRate($0) }
                )
            ) {
                ForEach(PlaybackRate.presets, id: \.self) { rate in
                    Text(ServiceController.playbackRateLabel(rate)).tag(rate)
                }
            }

            Button(controller.modelInstalled ? "Reload Kokoro" : "Download Kokoro") {
                controller.installOrLoadModel()
            }
            .disabled(controller.isBusy)

            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .disabled(!controller.canManageLaunchAtLogin)

            Divider()
            Button("Quit") {
                Task { await controller.quit() }
            }
        }
        .menuBarExtraStyle(.menu)
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
            modelPath: configuration.modelDirectory.appendingPathComponent(
                configuration.model.directoryName,
                isDirectory: true
            )
        )
        api = ReadBackAPI(
            configuration: configuration,
            modelStore: store,
            backend: backend,
            coordinator: coordinator,
            downloader: downloader
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

    static func playbackRateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
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

    private func startClipboardSpeech(_ text: String) {
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
                    status: "Ready — read \(text.count) characters"
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
