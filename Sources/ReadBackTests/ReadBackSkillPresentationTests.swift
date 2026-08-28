import ReadBackSkill

func readBackSkillPresentationTests() -> [TestCase] {
    [
        TestCase(name: "skill presentation offers install for a missing package") {
            let presentation = ReadBackSkillPresentation(
                snapshot: ReadBackSkillInstallSnapshot(state: .notInstalled)
            )
            try expectEqual(presentation.action, .install, "missing action")
            try expectEqual(presentation.actionTitle, "Install", "missing action title")
        },
        TestCase(name: "skill presentation offers remove for an installed package") {
            let presentation = ReadBackSkillPresentation(
                snapshot: ReadBackSkillInstallSnapshot(
                    state: .installed,
                    installedHosts: ReadBackSkillHost.allCases
                )
            )
            try expectEqual(presentation.action, .remove, "installed action")
            try expectEqual(
                presentation.status,
                "Installed for ChatGPT and Codex, Claude Code",
                "installed status"
            )
        },
        TestCase(name: "skill presentation offers update for an older package") {
            let presentation = ReadBackSkillPresentation(
                snapshot: ReadBackSkillInstallSnapshot(state: .updateAvailable)
            )
            try expectEqual(presentation.action, .update, "update action")
            try expectEqual(presentation.actionTitle, "Update", "update action title")
        },
        TestCase(name: "skill presentation blocks changes for a host conflict") {
            let presentation = ReadBackSkillPresentation(
                snapshot: ReadBackSkillInstallSnapshot(
                    state: .conflict,
                    conflictingHosts: [.claudeCode]
                )
            )
            try expectEqual(presentation.action, nil, "conflict action")
            try expect(
                presentation.status.contains("Claude Code"),
                "conflict should name the host"
            )
        },
        TestCase(name: "skill presentation explains a missing app resource") {
            let presentation = ReadBackSkillPresentation(
                snapshot: ReadBackSkillInstallSnapshot(state: .unavailable)
            )
            try expectEqual(presentation.action, nil, "unavailable action")
            try expectEqual(
                presentation.status,
                "The skill is missing from this app build",
                "unavailable status"
            )
        },
    ]
}
