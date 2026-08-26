import Foundation

public struct KokoroVoice: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let languageCode: String

    public init(id: String, name: String, languageCode: String) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
    }
}

public struct KokoroVoiceGroup: Equatable, Sendable {
    public let name: String
    public let voices: [KokoroVoice]

    public init(name: String, voices: [KokoroVoice]) {
        self.name = name
        self.voices = voices
    }
}

public enum KokoroVoiceCatalog {
    public static let curatedGroups: [KokoroVoiceGroup] = [
        KokoroVoiceGroup(
            name: "English",
            voices: [
                voice("af_heart", "Heart", "a"),
                voice("af_bella", "Bella", "a"),
                voice("af_nicole", "Nicole", "a"),
                voice("bf_emma", "Emma", "b"),
                voice("am_fenrir", "Fenrir", "a"),
                voice("am_michael", "Michael", "a"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Japanese",
            voices: [
                voice("jf_alpha", "Alpha", "j"),
                voice("jf_gongitsune", "Gongitsune", "j"),
                voice("jf_tebukuro", "Tebukuro", "j"),
                voice("jm_kumo", "Kumo", "j"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Mandarin Chinese",
            voices: [
                voice("zf_xiaoxiao", "Xiaoxiao", "z"),
                voice("zf_xiaoyi", "Xiaoyi", "z"),
                voice("zm_yunxi", "Yunxi", "z"),
                voice("zm_yunyang", "Yunyang", "z"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Spanish",
            voices: [
                voice("ef_dora", "Dora", "e"),
                voice("em_alex", "Alex", "e"),
                voice("em_santa", "Santa", "e"),
            ]
        ),
        KokoroVoiceGroup(
            name: "French",
            voices: [voice("ff_siwis", "Siwis", "f")]
        ),
        KokoroVoiceGroup(
            name: "Hindi",
            voices: [
                voice("hf_alpha", "Alpha", "h"),
                voice("hf_beta", "Beta", "h"),
                voice("hm_omega", "Omega", "h"),
                voice("hm_psi", "Psi", "h"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Italian",
            voices: [
                voice("if_sara", "Sara", "i"),
                voice("im_nicola", "Nicola", "i"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Brazilian Portuguese",
            voices: [
                voice("pf_dora", "Dora", "p"),
                voice("pm_alex", "Alex", "p"),
                voice("pm_santa", "Santa", "p"),
            ]
        ),
    ]

    public static func voice(id: String) -> KokoroVoice? {
        curatedGroups.lazy.flatMap(\.voices).first { $0.id == id }
    }

    public static func languageCode(forVoiceID id: String) -> String? {
        if let curated = voice(id: id) {
            return curated.languageCode
        }
        let filename = URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
        guard filename.count >= 2,
              let code = filename.first.map(String.init),
              ["a", "b", "j", "z", "e", "f", "h", "i", "p"].contains(code)
        else { return nil }
        return code
    }

    public static func availableGroups(
        in modelDirectory: URL,
        fileManager: FileManager = .default
    ) -> [KokoroVoiceGroup] {
        let voicesDirectory = modelDirectory.appendingPathComponent("voices", isDirectory: true)
        return curatedGroups.compactMap { group in
            let available = group.voices.filter { voice in
                fileManager.fileExists(
                    atPath: voicesDirectory.appendingPathComponent(
                        "\(voice.id).safetensors"
                    ).path
                )
            }
            return available.isEmpty ? nil : KokoroVoiceGroup(name: group.name, voices: available)
        }
    }

    private static func voice(
        _ id: String,
        _ name: String,
        _ languageCode: String
    ) -> KokoroVoice {
        KokoroVoice(id: id, name: name, languageCode: languageCode)
    }
}
