import Foundation
import ReadBackCore

func modelWorkspaceTests() -> [TestCase] {
    [
        TestCase(name: "model workspace links only bundled and installed voices") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundled = root.appendingPathComponent("Bundled", isDirectory: true)
            let installed = root.appendingPathComponent("Languages", isDirectory: true)
            let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundled.appendingPathComponent("voices", isDirectory: true),
                withIntermediateDirectories: true
            )
            for filename in ["config.json", "kokoro-v1_0.safetensors"] {
                try Data([1]).write(to: bundled.appendingPathComponent(filename))
            }
            for voiceID in ["af_heart", "ff_siwis", "jf_alpha"] {
                try Data([1]).write(
                    to: bundled
                        .appendingPathComponent("voices", isDirectory: true)
                        .appendingPathComponent("\(voiceID).safetensors")
                )
            }
            let installedVoices = installed
                .appendingPathComponent("ja/voices", isDirectory: true)
            try FileManager.default.createDirectory(
                at: installedVoices,
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: installedVoices.appendingPathComponent("jf_alpha.safetensors"))

            let workspace = ModelWorkspace(
                bundledModelURL: bundled,
                installedLanguagesURL: installed,
                runtimeModelURL: runtime
            )
            try workspace.prepare()

            try expect(
                FileManager.default.fileExists(
                    atPath: runtime.appendingPathComponent("voices/af_heart.safetensors").path
                ),
                "English voice should be linked"
            )
            try expect(
                FileManager.default.fileExists(
                    atPath: runtime.appendingPathComponent("voices/ff_siwis.safetensors").path
                ),
                "French voice should be linked"
            )
            try expect(
                FileManager.default.fileExists(
                    atPath: runtime.appendingPathComponent("voices/jf_alpha.safetensors").path
                ),
                "installed voice should be linked"
            )
        },
        TestCase(name: "language packs default to English and French") {
            try expectEqual(
                KokoroLanguagePackCatalog.bundled.map(\.id),
                ["en", "fr"],
                "bundled language IDs"
            )
            try expectEqual(
                Set(KokoroLanguagePackCatalog.downloadable.map(\.id)),
                Set(["ja", "zh", "es", "hi", "it", "pt"]),
                "downloadable language IDs"
            )
        },
    ]
}
