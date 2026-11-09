public enum ReadBackSkillAction: Equatable, Sendable {
    case install
    case update
    case remove
}

public struct ReadBackSkillPresentation: Equatable, Sendable {
    public let status: String
    public let action: ReadBackSkillAction?

    public init(snapshot: ReadBackSkillInstallSnapshot) {
        switch snapshot.state {
        case .notInstalled:
            let missing = ReadBackSkillHost.allCases.filter { !snapshot.installedHosts.contains($0) }
            status = snapshot.installedHosts.isEmpty
                ? "Not installed"
                : "Installed for \(Self.names(snapshot.installedHosts)). "
                    + "Install to add \(Self.names(missing))."
            action = .install
        case .installed:
            let hosts = snapshot.installedHosts.map(\.displayName).joined(separator: ", ")
            status = hosts.isEmpty ? "Installed" : "Installed for \(hosts)"
            action = .remove
        case .updateAvailable:
            status = "An update is ready"
            action = .update
        case .conflict:
            let hosts = snapshot.conflictingHosts.map(\.displayName).joined(separator: ", ")
            status = hosts.isEmpty
                ? "Another package uses the managed skill folder"
                : "Another readback skill already exists for \(hosts)"
            action = nil
        case .unavailable:
            status = "The skill is missing from this app build"
            action = nil
        }
    }

    private static func names(_ hosts: [ReadBackSkillHost]) -> String {
        hosts.map(\.displayName).joined(separator: ", ")
    }

    public var actionTitle: String? {
        switch action {
        case .install: "Install"
        case .update: "Update"
        case .remove: "Remove"
        case nil: nil
        }
    }
}
