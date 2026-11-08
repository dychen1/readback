import AppKit
import ReadBackService
import ReadBackSkill

@MainActor
extension ServiceController {
    var readBackSkillPresentation: ReadBackSkillPresentation {
        ReadBackSkillPresentation(snapshot: skillInstallSnapshot)
    }

    var mcpServerSetup: MCPServerSetup {
        MCPServerSetup(host: configuration.publicHost, port: configuration.publicPort)
    }

    var isCursorInstalled: Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: MCPServerSetup.cursorBundleIdentifier
        ) != nil
    }

    func installOrUpdateReadBackSkill() {
        guard !isChangingReadBackSkill else { return }
        isChangingReadBackSkill = true
        status = "Installing the ReadBack skill…"
        let installer = skillInstaller
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached {
                    try installer.install()
                    return try installer.snapshot()
                }.value
                guard let self else { return }
                skillInstallSnapshot = snapshot
                isChangingReadBackSkill = false
                status = "ReadBack skill installed"
            } catch {
                guard let self else { return }
                skillInstallSnapshot = (try? installer.snapshot())
                    ?? ReadBackSkillInstallSnapshot(state: .unavailable)
                isChangingReadBackSkill = false
                status = "Could not install the ReadBack skill: \(error.localizedDescription)"
            }
        }
    }

    /// Brings a ReadBack-owned skill install up to the bundled version.
    func updateInstalledReadBackSkill() {
        guard !isChangingReadBackSkill else { return }
        isChangingReadBackSkill = true
        let installer = skillInstaller
        Task { [weak self] in
            let result = await Task.detached {
                Result { try installer.updateInstalledPackageIfNeeded() }
            }.value
            guard let self else { return }
            skillInstallSnapshot = (try? installer.snapshot())
                ?? ReadBackSkillInstallSnapshot(state: .unavailable)
            isChangingReadBackSkill = false
            switch result {
            case .success(true):
                status = "ReadBack skill updated"
            case .success(false):
                break
            case .failure(let error):
                status = "Could not update the ReadBack skill: \(error.localizedDescription)"
            }
        }
    }

    func removeReadBackSkill() {
        guard !isChangingReadBackSkill else { return }
        isChangingReadBackSkill = true
        status = "Removing the ReadBack skill…"
        let installer = skillInstaller
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached {
                    try installer.remove()
                    return try installer.snapshot()
                }.value
                guard let self else { return }
                skillInstallSnapshot = snapshot
                isChangingReadBackSkill = false
                status = "ReadBack skill removed"
            } catch {
                guard let self else { return }
                isChangingReadBackSkill = false
                status = "Could not remove the ReadBack skill: \(error.localizedDescription)"
            }
        }
    }

    func openCursorMCPInstall() {
        if NSWorkspace.shared.open(mcpServerSetup.cursorInstallLink) {
            status = "Confirm adding the readback server in Cursor"
        } else {
            copy(mcpServerSetup.cursorConfiguration, confirmation: "Could not open Cursor. "
                + "Copied the configuration for ~/.cursor/mcp.json instead.")
        }
    }

    func copy(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            status = "Could not copy to the clipboard"
            return
        }
        status = confirmation
    }
}
