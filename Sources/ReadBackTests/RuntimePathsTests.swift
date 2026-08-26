import Foundation
import ReadBackCore

func runtimePathsTests() -> [TestCase] {
    [
        TestCase(name: "development app bundle finds the repository model directory") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dist/ReadBack Voice.app"),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent("Package.swift"))

            let paths = RuntimePaths.resolve(
                environment: [:],
                currentDirectory: URL(fileURLWithPath: "/"),
                bundleURL: root.appendingPathComponent("dist/ReadBack Voice.app")
            )

            try expectEqual(
                paths.modelsDirectory,
                root.appendingPathComponent("models", isDirectory: true).standardizedFileURL,
                "development model directory"
            )
        },
        TestCase(name: "installed app uses Application Support for models") {
            let paths = RuntimePaths.resolve(
                environment: [:],
                currentDirectory: URL(fileURLWithPath: "/"),
                bundleURL: URL(fileURLWithPath: "/Applications/ReadBack Voice.app")
            )
            try expect(
                paths.modelsDirectory.path.hasSuffix(
                    "/Library/Application Support/ReadBackVoice/models"
                ),
                "installed model directory"
            )
        },
    ]
}
