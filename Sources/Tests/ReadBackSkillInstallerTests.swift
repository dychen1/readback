import Foundation
import ReadBackSkill

func readBackSkillInstallerTests() -> [TestCase] {
    [
        TestCase(name: "skill installer publishes one managed package to both agent hosts") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }

            try fixture.installer.install()

            let snapshot = try fixture.installer.snapshot()
            try expectEqual(snapshot.state, .installed, "installed state")
            try expectEqual(
                Set(snapshot.installedHosts),
                Set(ReadBackSkillHost.allCases),
                "installed hosts"
            )
            let managedSkill = try String(
                contentsOf: fixture.managedURL.appendingPathComponent("SKILL.md")
            )
            try expectEqual(
                managedSkill,
                "skill version one",
                "managed skill contents"
            )
            for host in ReadBackSkillHost.allCases {
                let destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixture.hostURLs[host]!.path
                )
                try expectEqual(destination, fixture.managedURL.path, "\(host) link destination")
            }

            try fixture.installer.install()
            let idempotentState = try fixture.installer.snapshot().state
            try expectEqual(idempotentState, .installed, "idempotent state")
        },
        TestCase(name: "skill installer replaces an older managed package") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }
            try fixture.installer.install()
            try fixture.writeSource(version: "2.0.0", skill: "skill version two")

            let updateState = try fixture.installer.snapshot().state
            try expectEqual(updateState, .updateAvailable, "update state")
            try fixture.installer.install()

            let updatedState = try fixture.installer.snapshot().state
            let updatedSkill = try String(
                contentsOf: fixture.managedURL.appendingPathComponent("SKILL.md")
            )
            try expectEqual(updatedState, .installed, "updated state")
            try expectEqual(
                updatedSkill,
                "skill version two",
                "updated skill contents"
            )
        },
        TestCase(name: "skill installer leaves every path unchanged when a host conflicts") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }
            let conflictURL = fixture.hostURLs[.claudeCode]!
            try FileManager.default.createDirectory(
                at: conflictURL,
                withIntermediateDirectories: true
            )
            try Data("keep me".utf8).write(to: conflictURL.appendingPathComponent("owner.txt"))

            let snapshot = try fixture.installer.snapshot()
            try expectEqual(snapshot.state, .conflict, "conflict state")
            try expectEqual(snapshot.conflictingHosts, [.claudeCode], "conflicting hosts")
            do {
                try fixture.installer.install()
                throw TestFailure(description: "conflicting install should fail")
            } catch ReadBackSkillInstallerError.conflict(let hosts) {
                try expectEqual(hosts, [.claudeCode], "install conflict hosts")
            }

            try expect(
                !FileManager.default.fileExists(atPath: fixture.managedURL.path),
                "managed package must not be created"
            )
            try expect(
                !FileManager.default.fileExists(atPath: fixture.hostURLs[.openAI]!.path),
                "other host must remain unchanged"
            )
            try expect(
                FileManager.default.fileExists(atPath: conflictURL.appendingPathComponent("owner.txt").path),
                "conflicting directory must remain"
            )
        },
        TestCase(name: "skill installer remove deletes only ReadBack-owned links") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }
            try fixture.installer.install()
            let openAIURL = fixture.hostURLs[.openAI]!
            try FileManager.default.removeItem(at: openAIURL)
            let foreignURL = fixture.root.appendingPathComponent("foreign-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: foreignURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: openAIURL, withDestinationURL: foreignURL)

            try fixture.installer.remove()

            try expect(
                FileManager.default.fileExists(atPath: openAIURL.path),
                "foreign link must remain"
            )
            try expect(
                !FileManager.default.fileExists(atPath: fixture.hostURLs[.claudeCode]!.path),
                "owned Claude link must be removed"
            )
            try expect(
                !FileManager.default.fileExists(atPath: fixture.managedURL.path),
                "managed package must be removed"
            )
        },
        TestCase(name: "skill installer treats an existing Cursor link to the managed package as its own") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }
            let cursorURL = fixture.hostURLs[.cursor]!
            try FileManager.default.createDirectory(
                at: cursorURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: cursorURL.path,
                withDestinationPath: fixture.managedURL.path
            )

            let before = try fixture.installer.snapshot()
            try expect(before.state != .conflict, "a link to the managed folder is not a conflict")
            try fixture.installer.install()

            let after = try fixture.installer.snapshot()
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: cursorURL.path)
            try expectEqual(after.state, .installed, "installed for every host")
            try expectEqual(destination, fixture.managedURL.path, "existing Cursor link is kept")
        },
        TestCase(name: "skill auto-update refreshes an owned package without touching host folders") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }
            try fixture.installer.install()
            let cursorURL = fixture.hostURLs[.cursor]!
            try FileManager.default.removeItem(at: cursorURL)
            try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: true)
            try Data("someone else's skill".utf8).write(to: cursorURL.appendingPathComponent("SKILL.md"))
            try fixture.writeSource(version: "2.0.0", skill: "skill version two")

            let updated = try fixture.installer.updateInstalledPackageIfNeeded()

            let managedSkill = try String(contentsOf: fixture.managedURL.appendingPathComponent("SKILL.md"))
            let linkedSkill = try String(
                contentsOf: fixture.hostURLs[.claudeCode]!.appendingPathComponent("SKILL.md")
            )
            let conflictingSkill = try String(contentsOf: cursorURL.appendingPathComponent("SKILL.md"))
            try expect(updated, "owned package is updated")
            try expectEqual(managedSkill, "skill version two", "managed package has the bundled version")
            try expectEqual(linkedSkill, "skill version two", "linked host sees the update through its link")
            try expectEqual(conflictingSkill, "someone else's skill", "conflicting host folder is untouched")
            let repeated = try fixture.installer.updateInstalledPackageIfNeeded()
            try expect(!repeated, "nothing to do once versions match")
        },
        TestCase(name: "skill auto-update never installs or replaces a foreign package") {
            let notInstalled = try SkillInstallerFixture()
            defer { notInstalled.cleanup() }
            let installedNothing = try notInstalled.installer.updateInstalledPackageIfNeeded()
            try expect(!installedNothing, "no install happens on update")
            try expect(
                !FileManager.default.fileExists(atPath: notInstalled.managedURL.path),
                "managed folder is not created"
            )

            let foreign = try SkillInstallerFixture()
            defer { foreign.cleanup() }
            try FileManager.default.createDirectory(at: foreign.managedURL, withIntermediateDirectories: true)
            let foreignManifest = #"{"owner":"someone.else","schema_version":1,"skill_version":"0.1"}"#
            try Data(foreignManifest.utf8).write(to: foreign.managedURL.appendingPathComponent("manifest.json"))

            let updatedForeign = try foreign.installer.updateInstalledPackageIfNeeded()
            let manifestAfter = try String(contentsOf: foreign.managedURL.appendingPathComponent("manifest.json"))
            try expect(!updatedForeign, "foreign package is not updated")
            try expectEqual(manifestAfter, foreignManifest, "foreign package is unchanged")
        },
        TestCase(name: "skill installer reports an unavailable bundled source") {
            let fixture = try SkillInstallerFixture(createSource: false)
            defer { fixture.cleanup() }

            let state = try fixture.installer.snapshot().state
            try expectEqual(state, .unavailable, "missing source state")
        },
        TestCase(name: "skill installer rejects a source without its native client") {
            let fixture = try SkillInstallerFixture()
            defer { fixture.cleanup() }
            try FileManager.default.removeItem(
                at: fixture.sourceURL.appendingPathComponent("scripts/readback-skill-client")
            )

            let state = try fixture.installer.snapshot().state
            try expectEqual(state, .unavailable, "missing client state")
            do {
                try fixture.installer.install()
                throw TestFailure(description: "source without client should not install")
            } catch ReadBackSkillInstallerError.sourceUnavailable {
            }
        },
    ]
}

private final class SkillInstallerFixture {
    let root: URL
    let sourceURL: URL
    let managedURL: URL
    let hostURLs: [ReadBackSkillHost: URL]
    let installer: ReadBackSkillInstaller

    init(createSource: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readback-skill-installer-\(UUID().uuidString)", isDirectory: true)
        sourceURL = root.appendingPathComponent("bundle/readback", isDirectory: true)
        managedURL = root.appendingPathComponent("support/Skills/readback", isDirectory: true)
        hostURLs = [
            .openAI: root.appendingPathComponent("home/.agents/skills/readback", isDirectory: true),
            .claudeCode: root.appendingPathComponent("home/.claude/skills/readback", isDirectory: true),
            .cursor: root.appendingPathComponent("home/.cursor/skills/readback", isDirectory: true),
        ]
        installer = ReadBackSkillInstaller(
            sourceURL: sourceURL,
            managedURL: managedURL,
            hostURLs: hostURLs
        )
        if createSource {
            try writeSource(version: "1.0.0", skill: "skill version one")
        }
    }

    func writeSource(version: String, skill: String) throws {
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.removeItem(at: sourceURL)
        }
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent("agents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(skill.utf8).write(to: sourceURL.appendingPathComponent("SKILL.md"))
        try Data("interface: {}\n".utf8).write(
            to: sourceURL.appendingPathComponent("agents/openai.yaml")
        )
        let clientURL = sourceURL.appendingPathComponent("scripts/readback-skill-client")
        try FileManager.default.createDirectory(
            at: clientURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("client".utf8).write(to: clientURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: clientURL.path
        )
        let manifest = """
        {"owner":"ai.sanrin.readback","schema_version":1,"skill_version":"\(version)"}
        """
        try Data(manifest.utf8).write(to: sourceURL.appendingPathComponent("manifest.json"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
