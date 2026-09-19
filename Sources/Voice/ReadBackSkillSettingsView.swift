import ReadBackSkill
import SwiftUI

struct ReadBackSkillSettingsView: View {
    @ObservedObject var controller: ServiceController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("ReadBack Skill")
                Text("Adapt and speak the latest reply from local ChatGPT, Codex, or Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.readBackSkillPresentation.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if controller.isChangingReadBackSkill {
                ProgressView()
                    .controlSize(.small)
            } else if let action = controller.readBackSkillPresentation.action,
                      let title = controller.readBackSkillPresentation.actionTitle
            {
                Button(
                    title,
                    role: action == .remove ? .destructive : nil
                ) {
                    switch action {
                    case .install, .update:
                        controller.installOrUpdateReadBackSkill()
                    case .remove:
                        controller.removeReadBackSkill()
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
