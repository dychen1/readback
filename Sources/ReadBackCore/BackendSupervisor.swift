import Foundation

public struct BackendLaunchCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public static func mlxAudio(port: Int) -> BackendLaunchCommand {
        BackendLaunchCommand(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            arguments: [
                "run",
                "--python",
                "3.12",
                "--with",
                "mlx-audio[server]==0.5.0",
                "--with",
                "misaki[en]==0.9.4",
                "python",
                "-m",
                "mlx_audio.server",
                "--host",
                "127.0.0.1",
                "--port",
                String(port),
            ]
        )
    }
}

public actor BackendSupervisor {
    private let command: BackendLaunchCommand
    private let logURL: URL
    private var process: Process?
    private var logHandle: FileHandle?

    public init(command: BackendLaunchCommand, logURL: URL) {
        self.command = command
        self.logURL = logURL
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func start() throws {
        guard process?.isRunning != true else {
            return
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = logURL.deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"],
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        self.logHandle = handle
        self.process = process
    }

    public func stop() {
        guard let process else {
            return
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? logHandle?.close()
        logHandle = nil
        self.process = nil
    }
}
