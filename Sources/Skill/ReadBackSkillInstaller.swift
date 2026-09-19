import Foundation

public enum ReadBackSkillHost: String, CaseIterable, Codable, Hashable, Sendable {
    case openAI
    case claudeCode

    public var displayName: String {
        switch self {
        case .openAI: "ChatGPT and Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public enum ReadBackSkillInstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case updateAvailable
    case conflict
    case unavailable
}

public struct ReadBackSkillInstallSnapshot: Equatable, Sendable {
    public let state: ReadBackSkillInstallState
    public let installedHosts: [ReadBackSkillHost]
    public let conflictingHosts: [ReadBackSkillHost]

    public init(
        state: ReadBackSkillInstallState,
        installedHosts: [ReadBackSkillHost] = [],
        conflictingHosts: [ReadBackSkillHost] = []
    ) {
        self.state = state
        self.installedHosts = installedHosts
        self.conflictingHosts = conflictingHosts
    }
}

public enum ReadBackSkillInstallerError: LocalizedError, Sendable {
    case sourceUnavailable
    case conflict([ReadBackSkillHost])
    case managedPackageConflict

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The ReadBack skill is missing from this app."
        case .conflict(let hosts):
            "A different readback skill already exists for \(hosts.map(\.displayName).joined(separator: ", "))."
        case .managedPackageConflict:
            "A skill package not owned by ReadBack already uses the managed install folder."
        }
    }
}

public struct ReadBackSkillInstaller: @unchecked Sendable {
    private struct Manifest: Codable, Equatable {
        let owner: String
        let schemaVersion: Int
        let skillVersion: String

        private enum CodingKeys: String, CodingKey {
            case owner
            case schemaVersion = "schema_version"
            case skillVersion = "skill_version"
        }

        var isOwnedByReadBack: Bool {
            owner == "ai.sanrin.readback" && schemaVersion == 1 && !skillVersion.isEmpty
        }
    }

    public let sourceURL: URL
    public let managedURL: URL
    public let hostURLs: [ReadBackSkillHost: URL]
    private let fileManager: FileManager

    public init(
        sourceURL: URL,
        managedURL: URL,
        hostURLs: [ReadBackSkillHost: URL],
        fileManager: FileManager = .default
    ) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.managedURL = managedURL.standardizedFileURL
        self.hostURLs = hostURLs.mapValues(\.standardizedFileURL)
        self.fileManager = fileManager
    }

    public func snapshot() throws -> ReadBackSkillInstallSnapshot {
        guard packageIsComplete(at: sourceURL),
              let sourceManifest = try? manifest(at: sourceURL),
              sourceManifest.isOwnedByReadBack
        else {
            return ReadBackSkillInstallSnapshot(state: .unavailable)
        }

        let conflictingHosts = ReadBackSkillHost.allCases.filter { host in
            guard let url = hostURLs[host], itemExists(at: url) else { return false }
            return !isOwnedHostLink(at: url)
        }
        if !conflictingHosts.isEmpty {
            return ReadBackSkillInstallSnapshot(
                state: .conflict,
                installedHosts: installedHosts(),
                conflictingHosts: conflictingHosts
            )
        }

        guard itemExists(at: managedURL) else {
            return ReadBackSkillInstallSnapshot(
                state: .notInstalled,
                installedHosts: installedHosts()
            )
        }
        guard let managedManifest = try? manifest(at: managedURL),
              managedManifest.isOwnedByReadBack
        else {
            return ReadBackSkillInstallSnapshot(state: .conflict)
        }

        let installed = installedHosts()
        if !packageIsComplete(at: managedURL)
            || managedManifest.skillVersion != sourceManifest.skillVersion
        {
            return ReadBackSkillInstallSnapshot(
                state: .updateAvailable,
                installedHosts: installed
            )
        }
        return ReadBackSkillInstallSnapshot(
            state: installed.count == ReadBackSkillHost.allCases.count
                ? .installed
                : .notInstalled,
            installedHosts: installed
        )
    }

    public func install() throws {
        guard packageIsComplete(at: sourceURL),
              let sourceManifest = try? manifest(at: sourceURL),
              sourceManifest.isOwnedByReadBack
        else {
            throw ReadBackSkillInstallerError.sourceUnavailable
        }

        let conflicts = ReadBackSkillHost.allCases.filter { host in
            guard let url = hostURLs[host], itemExists(at: url) else { return false }
            return !isOwnedHostLink(at: url)
        }
        guard conflicts.isEmpty else {
            throw ReadBackSkillInstallerError.conflict(conflicts)
        }
        if itemExists(at: managedURL) {
            guard let existingManifest = try? manifest(at: managedURL),
                  existingManifest.isOwnedByReadBack
            else {
                throw ReadBackSkillInstallerError.managedPackageConflict
            }
        }

        try publishManagedPackage()
        for host in ReadBackSkillHost.allCases {
            guard let hostURL = hostURLs[host] else { continue }
            if isOwnedHostLink(at: hostURL) {
                continue
            }
            try fileManager.createDirectory(
                at: hostURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: hostURL, withDestinationURL: managedURL)
        }
    }

    public func remove() throws {
        for host in ReadBackSkillHost.allCases {
            guard let hostURL = hostURLs[host], isOwnedHostLink(at: hostURL) else { continue }
            try fileManager.removeItem(at: hostURL)
        }
        guard itemExists(at: managedURL),
              let existingManifest = try? manifest(at: managedURL),
              existingManifest.isOwnedByReadBack
        else { return }
        try fileManager.removeItem(at: managedURL)
    }

    private func publishManagedPackage() throws {
        let parent = managedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(
            ".readback-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".readback-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: stage)
            try? fileManager.removeItem(at: backup)
        }

        try fileManager.copyItem(at: sourceURL, to: stage)
        if itemExists(at: managedURL) {
            try fileManager.moveItem(at: managedURL, to: backup)
            do {
                try fileManager.moveItem(at: stage, to: managedURL)
                try fileManager.removeItem(at: backup)
            } catch {
                if !itemExists(at: managedURL), itemExists(at: backup) {
                    try? fileManager.moveItem(at: backup, to: managedURL)
                }
                throw error
            }
        } else {
            try fileManager.moveItem(at: stage, to: managedURL)
        }
    }

    private func installedHosts() -> [ReadBackSkillHost] {
        ReadBackSkillHost.allCases.filter { host in
            hostURLs[host].map(isOwnedHostLink(at:)) ?? false
        }
    }

    private func isOwnedHostLink(at url: URL) -> Bool {
        guard isSymbolicLink(at: url),
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path)
        else { return false }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL == managedURL
    }

    private func manifest(at packageURL: URL) throws -> Manifest {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func packageIsComplete(at packageURL: URL) -> Bool {
        let requiredFiles = [
            packageURL.appendingPathComponent("SKILL.md"),
            packageURL.appendingPathComponent("agents/openai.yaml"),
            packageURL.appendingPathComponent("manifest.json"),
        ]
        guard requiredFiles.allSatisfy({ itemExists(at: $0) }) else { return false }
        return fileManager.isExecutableFile(
            atPath: packageURL.appendingPathComponent(
                "scripts/readback-skill-client"
            ).path
        )
    }

    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}
