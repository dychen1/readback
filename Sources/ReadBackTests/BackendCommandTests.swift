import Foundation
import ReadBackCore

func backendCommandTests() -> [TestCase] {
    [
        TestCase(name: "backend command pins runtime package and loopback port") {
            let command = BackendLaunchCommand.mlxAudio(port: 51_281)

            try expectEqual(
                command.executableURL.path,
                "/opt/homebrew/bin/uv",
                "backend executable"
            )
            try expectEqual(
                command.arguments,
                [
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
                    "51281",
                ],
                "backend arguments"
            )
        },
        TestCase(name: "backend supervisor launches in its writable support directory") {
            let supportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: supportDirectory) }
            let logURL = supportDirectory.appendingPathComponent("backend.log")
            let supervisor = BackendSupervisor(
                command: BackendLaunchCommand(
                    executableURL: URL(fileURLWithPath: "/bin/pwd"),
                    arguments: []
                ),
                logURL: logURL
            )

            try await supervisor.start()
            for _ in 0..<100 where await supervisor.isRunning {
                try await Task.sleep(for: .milliseconds(10))
            }
            await supervisor.stop()

            let output = try String(contentsOf: logURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedOutput = URL(fileURLWithPath: output).resolvingSymlinksInPath().path
            let resolvedSupport = supportDirectory.resolvingSymlinksInPath().path
            try expectEqual(resolvedOutput, resolvedSupport, "backend working directory")
        },
    ]
}
