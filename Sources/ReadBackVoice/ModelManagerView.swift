import Foundation
import ReadBackCore
import SwiftUI

struct ModelManagerView: View {
    @ObservedObject var controller: ServiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.title2.bold())
                Text("Manage agent read-back and voice models.")
                    .foregroundStyle(.secondary)
            }

            List {
                Section("Agent Read-Back") {
                    ReadBackSkillSettingsView(controller: controller)
                }

                Section("Installed") {
                    ForEach(controller.installedModels) { model in
                        modelRow(model)
                    }
                }

                if !controller.availableModels.isEmpty {
                    Section("Available") {
                        ForEach(controller.availableModels) { model in
                            modelRow(model)
                        }
                    }
                }

                Section("Local") {
                    Button("Choose Local MLX Model…") {
                        controller.chooseLocalModel()
                    }
                    .disabled(!controller.canChangeModel)
                }

                if !controller.activeLanguages.isEmpty {
                    Section("Languages for \(controller.activeModelName)") {
                        ForEach(controller.activeLanguages) { language in
                            HStack {
                                Text(language.displayName)
                                Spacer()
                                if language.isInstalled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else if language.canInstall {
                                    Button("Install") {
                                        controller.installLanguage(language)
                                    }
                                    .disabled(controller.installingLanguageID != nil)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(20)
    }

    @ViewBuilder
    private func modelRow(_ model: ModelSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.id == controller.activeModelID ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
                .foregroundStyle(
                    model.id == controller.activeModelID
                        ? Color.accentColor
                        : Color.secondary
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text(detailLabel(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.id == controller.activeModelID {
                Text("Active")
                    .foregroundStyle(.secondary)
            } else if case .downloading(let progress) = model.storageState {
                ProgressView(value: progress)
                    .frame(width: 90)
                Button("Cancel") {
                    controller.cancelModelInstallation()
                }
            } else if model.canActivate {
                Button("Use") { controller.activateModel(model.id) }
                    .disabled(!controller.canChangeModel)
            } else if model.canInstall {
                Button("Install") { controller.installModel(model) }
            }
            if model.canRemove {
                Button(role: .destructive) {
                    controller.removeModel(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }

    private func originLabel(_ origin: ModelOrigin) -> String {
        switch origin {
        case .bundled: "Included with ReadBack"
        case .managedDownload: "Managed by ReadBack"
        case .local: "Local folder"
        }
    }

    private func detailLabel(_ model: ModelSnapshot) -> String {
        if case .downloading(let progress) = model.storageState {
            return "Downloading \(Int((progress * 100).rounded()))%"
        }
        var parts = [originLabel(model.origin)]
        if let downloadSize = model.downloadSize, downloadSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file))
        }
        let languages = model.languages.map(\.displayName)
        if !languages.isEmpty {
            parts.append(languages.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
