import AppKit
import Foundation
import ReadBackSkill

private enum ReadBackWorkspaceLauncherError: LocalizedError {
    case applicationNotFound

    var errorDescription: String? {
        "ReadBack is not installed. Install or open ReadBack, then try again."
    }
}

private struct ReadBackWorkspaceLauncher: ReadBackAppLaunching {
    func launch() async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "ai.sanrin.readback"
        ) else {
            throw ReadBackWorkspaceLauncherError.applicationNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

@main
enum ReadBackSkillCommand {
    static func main() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = try ReadBackSkillCommandInput.parse(
                arguments: Array(CommandLine.arguments.dropFirst()),
                data: data
            )
            let client = ReadBackSkillClient(
                transport: URLSessionReadBackSkillTransport(),
                launcher: ReadBackWorkspaceLauncher()
            )
            try await client.play(text)
        } catch {
            let message = "readback: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(1)
        }
    }
}
