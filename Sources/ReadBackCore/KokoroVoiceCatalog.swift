import Foundation

public struct KokoroVoice: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let languageCode: String

    public init(id: String, name: String, detail: String, languageCode: String) {
        self.id = id
        self.name = name
        self.detail = detail
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
            name: "Recommended English",
            voices: [
                voice("af_heart", "Heart", "American · Female", "a"),
                voice("af_bella", "Bella", "American · Female", "a"),
                voice("af_nicole", "Nicole", "American · Female", "a"),
                voice("bf_emma", "Emma", "British · Female", "b"),
            ]
        ),
        KokoroVoiceGroup(
            name: "English — Male",
            voices: [
                voice("am_fenrir", "Fenrir", "American · Male", "a"),
                voice("am_michael", "Michael", "American · Male", "a"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Japanese",
            voices: [
                voice("jf_alpha", "Alpha", "Female", "j"),
                voice("jf_gongitsune", "Gongitsune", "Female", "j"),
                voice("jf_tebukuro", "Tebukuro", "Female", "j"),
                voice("jm_kumo", "Kumo", "Male", "j"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Mandarin Chinese",
            voices: [
                voice("zf_xiaoxiao", "Xiaoxiao", "Female", "z"),
                voice("zf_xiaoyi", "Xiaoyi", "Female", "z"),
                voice("zm_yunxi", "Yunxi", "Male", "z"),
                voice("zm_yunyang", "Yunyang", "Male", "z"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Spanish",
            voices: [
                voice("ef_dora", "Dora", "Female", "e"),
                voice("em_alex", "Alex", "Male", "e"),
                voice("em_santa", "Santa", "Male", "e"),
            ]
        ),
        KokoroVoiceGroup(
            name: "French",
            voices: [voice("ff_siwis", "Siwis", "Female", "f")]
        ),
        KokoroVoiceGroup(
            name: "Hindi",
            voices: [
                voice("hf_alpha", "Alpha", "Female", "h"),
                voice("hf_beta", "Beta", "Female", "h"),
                voice("hm_omega", "Omega", "Male", "h"),
                voice("hm_psi", "Psi", "Male", "h"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Italian",
            voices: [
                voice("if_sara", "Sara", "Female", "i"),
                voice("im_nicola", "Nicola", "Male", "i"),
            ]
        ),
        KokoroVoiceGroup(
            name: "Brazilian Portuguese",
            voices: [
                voice("pf_dora", "Dora", "Female", "p"),
                voice("pm_alex", "Alex", "Male", "p"),
                voice("pm_santa", "Santa", "Male", "p"),
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
        _ detail: String,
        _ languageCode: String
    ) -> KokoroVoice {
        KokoroVoice(id: id, name: name, detail: detail, languageCode: languageCode)
    }
}
