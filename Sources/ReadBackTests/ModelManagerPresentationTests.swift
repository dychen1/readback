import ReadBackCore

func modelManagerPresentationTests() -> [TestCase] {
    [
        TestCase(name: "model presentation separates installed and available entries") {
            let installed = ModelSnapshot(
                id: .kokoro,
                displayName: "Kokoro",
                origin: .bundled,
                storageState: .bundled,
                languages: [],
                canInstall: false,
                canRemove: false,
                canActivate: false
            )
            let availableID = ModelID(rawValue: "fixture")
            let available = ModelSnapshot(
                id: availableID,
                displayName: "Fixture",
                origin: .managedDownload,
                storageState: .notInstalled,
                languages: [],
                canInstall: true,
                canRemove: false,
                canActivate: false
            )
            let presentation = ModelManagerPresentation(
                snapshot: ModelManagerSnapshot(
                    models: [available, installed],
                    activeModelID: .kokoro,
                    activePreferences: nil,
                    runtimeState: .ready(.kokoro),
                    operation: .idle
                )
            )

            try expectEqual(presentation.installed.map(\.id), [.kokoro], "installed")
            try expectEqual(presentation.available.map(\.id), [availableID], "available")
        },
        TestCase(name: "model presentation exposes installed languages and voices") {
            let language = ModelLanguageSnapshot(
                code: "en",
                displayName: "English",
                voices: [
                    ModelVoiceDefinition(
                        id: "af_heart",
                        displayName: "Heart",
                        languageCode: "a"
                    )
                ],
                isInstalled: true,
                canInstall: false
            )
            let model = ModelSnapshot(
                id: .kokoro,
                displayName: "Kokoro",
                origin: .bundled,
                storageState: .bundled,
                languages: [language],
                canInstall: false,
                canRemove: false,
                canActivate: false
            )
            let presentation = ModelManagerPresentation(
                snapshot: ModelManagerSnapshot(
                    models: [model],
                    activeModelID: .kokoro,
                    activePreferences: ModelPreference(
                        modelID: .kokoro,
                        voiceID: "af_heart",
                        languageCode: "en",
                        synthesisSpeed: 1
                    ),
                    runtimeState: .ready(.kokoro),
                    operation: .idle
                )
            )

            try expectEqual(presentation.activeModel?.displayName, "Kokoro", "active model")
            try expectEqual(presentation.activeLanguages.map(\.code), ["en"], "languages")
            try expectEqual(presentation.activeVoices.map(\.id), ["af_heart"], "voices")
        },
    ]
}
