import Foundation

public struct KokoroLanguagePack: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let languageIdentifier: String
    public let voices: [KokoroVoice]
    public let lexiconFilename: String?
    public let isBundled: Bool

    public init(
        id: String,
        name: String,
        languageIdentifier: String,
        voices: [KokoroVoice],
        lexiconFilename: String?,
        isBundled: Bool
    ) {
        self.id = id
        self.name = name
        self.languageIdentifier = languageIdentifier
        self.voices = voices
        self.lexiconFilename = lexiconFilename
        self.isBundled = isBundled
    }
}

public enum KokoroLanguagePackCatalog {
    public static let all: [KokoroLanguagePack] = [
        pack("en", "English", "en-us", bundled: true),
        pack("fr", "French", "fr", lexicon: "fr_lexicon.tsv", bundled: true),
        pack("ja", "Japanese", "ja"),
        pack("zh", "Mandarin Chinese", "cmn"),
        pack("es", "Spanish", "es", lexicon: "es_lexicon.tsv"),
        pack("hi", "Hindi", "hi"),
        pack("it", "Italian", "it", lexicon: "it_lexicon.tsv"),
        pack("pt", "Brazilian Portuguese", "pt", lexicon: "pt_lexicon.tsv"),
    ]

    public static let bundled = all.filter(\.isBundled)
    public static let downloadable = all.filter { !$0.isBundled }

    public static func pack(id: String) -> KokoroLanguagePack? {
        all.first { $0.id == id }
    }

    private static func pack(
        _ id: String,
        _ name: String,
        _ languageIdentifier: String,
        lexicon: String? = nil,
        bundled: Bool = false
    ) -> KokoroLanguagePack {
        let voices = KokoroVoiceCatalog.curatedGroups
            .first { $0.name == name }?
            .voices ?? []
        return KokoroLanguagePack(
            id: id,
            name: name,
            languageIdentifier: languageIdentifier,
            voices: voices,
            lexiconFilename: lexicon,
            isBundled: bundled
        )
    }
}
