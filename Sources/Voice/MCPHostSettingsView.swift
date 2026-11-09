import ReadBackService
import SwiftUI

struct MCPServerSettingsHeader: View {
    let endpoint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("MCP Server")
            Text("Connect an agent app to \(endpoint). Then the skill can use the ReadBack play tool.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}

struct MCPHostSettingsRow: View {
    let host: MCPHost
    @ObservedObject var controller: ServiceController

    var body: some View {
        let setup = controller.mcpServerSetup
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: host == .cursor ? "cursorarrow.rays" : "terminal")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(
                        MCPConnectionStatus.text(
                            for: host,
                            connections: controller.mcpConnections,
                            now: context.date
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let instruction = instruction(setup) {
                    Text(instruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let snippet = snippet(setup) {
                    Text(snippet)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            action(setup)
        }
        .padding(.vertical, 3)
    }

    private func instruction(_ setup: MCPServerSetup) -> String? {
        switch host {
        case .cursor:
            controller.isCursorInstalled
                ? "Opens Cursor. Confirm the readback server there."
                : "Add this to ~/.cursor/mcp.json:"
        case .claudeCode, .codex:
            "Run in Terminal:"
        }
    }

    private func snippet(_ setup: MCPServerSetup) -> String? {
        switch host {
        case .cursor: controller.isCursorInstalled ? nil : setup.cursorConfiguration
        case .claudeCode: setup.claudeCodeCommand
        case .codex: setup.codexCommand
        }
    }

    @ViewBuilder
    private func action(_ setup: MCPServerSetup) -> some View {
        switch host {
        case .cursor where controller.isCursorInstalled:
            Button("Add to Cursor") { controller.openCursorMCPInstall() }
        case .cursor:
            Button("Copy JSON") {
                controller.copy(
                    setup.cursorConfiguration,
                    confirmation: "Copied the Cursor configuration"
                )
            }
        case .claudeCode:
            Button("Copy Command") {
                controller.copy(
                    setup.claudeCodeCommand,
                    confirmation: "Copied the Claude Code command"
                )
            }
        case .codex:
            Button("Copy Command") {
                controller.copy(setup.codexCommand, confirmation: "Copied the Codex command")
            }
        }
    }
}

struct MCPOtherClientsRow: View {
    @ObservedObject var controller: ServiceController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let text = MCPConnectionStatus.otherClientsText(
                connections: controller.mcpConnections,
                now: context.date
            ) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
