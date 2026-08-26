import Foundation
import ReadBackCore

func voiceCatalogTests() -> [TestCase] {
    [
        TestCase(name: "voice catalog exposes only the curated installed voices") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let voices = root.appendingPathComponent("voices", isDirectory: true)
            try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
            for id in [
                "af_heart", "af_bella", "af_nicole", "bf_emma", "af_alloy",
                "am_fenrir", "am_michael",
                "jf_alpha", "jf_gongitsune", "jf_tebukuro", "jm_kumo",
            ] {
                try Data([0x01]).write(
                    to: voices.appendingPathComponent("\(id).safetensors")
                )
            }

            let groups = KokoroVoiceCatalog.availableGroups(in: root)

            try expectEqual(
                groups.map(\.name),
                ["Recommended English", "English — Male", "Japanese"],
                "available voice groups"
            )
            try expectEqual(
                groups[0].voices.map(\.id),
                ["af_heart", "af_bella", "af_nicole", "bf_emma"],
                "recommended English voices"
            )
            try expectEqual(
                groups[1].voices.map(\.id),
                ["am_fenrir", "am_michael"],
                "recommended English male voices"
            )
            try expectEqual(
                groups[2].voices.map(\.id),
                ["jf_alpha", "jf_gongitsune", "jf_tebukuro", "jm_kumo"],
                "curated Japanese voices"
            )
            try expect(
                groups.allSatisfy { $0.voices.count <= 4 },
                "no language group may expose more than four voices"
            )
        },
        TestCase(name: "voice catalog maps each curated voice to its language code") {
            let expected = [
                "af_heart": "a",
                "bf_emma": "b",
                "jf_alpha": "j",
                "zf_xiaoxiao": "z",
                "ef_dora": "e",
                "ff_siwis": "f",
                "hf_alpha": "h",
                "if_sara": "i",
                "pf_dora": "p",
            ]

            for (voiceID, languageCode) in expected {
                try expectEqual(
                    KokoroVoiceCatalog.voice(id: voiceID)?.languageCode,
                    languageCode,
                    "language code for \(voiceID)"
                )
            }
        },
    ]
}
