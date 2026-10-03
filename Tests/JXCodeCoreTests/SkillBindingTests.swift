import XCTest
@testable import JXCodeCore

/// Native skill binding: the symlinks, the permission gate they depend on, and
/// the refusals that keep both honest.
///
/// Split out from `SharedCollectionTests` because it is the half of the skill
/// story that is *not* JXCode's own format. Once a skill is a symlink into an
/// agent's directory, the agent parses the file itself and JXCode's opinion of
/// it stops mattering — so every test here is about what a third party will
/// find, not about what the store holds.
final class SkillBindingTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-skillbinding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func skill(
        id: String = "release",
        name: String = "Release checklist",
        summary: String = "Steps before tagging",
        body: String? = nil
    ) -> Skill {
        Skill(
            id: id,
            name: name,
            summary: summary,
            body: body ?? "# \(name)\n\nRun the suite."
        )
    }

    private func connector() -> Connector {
        Connector(
            id: "filesystem",
            name: "filesystem",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem"]
        )
    }

    private func apply(_ skills: [Skill]) throws -> [SkillBinder.Report] {
        try SkillBinder.apply(skills: skills, agents: AgentRegistry.builtIns, paths: paths)
    }

    private func notes(for agentID: String, in reports: [SkillBinder.Report]) throws -> [String] {
        try XCTUnwrap(reports.first { $0.agentID == agentID }).notes
    }

    /// Where a link at `directory/<id>` points, or `nil` if there is no link.
    private func linkTarget(_ id: String, in directory: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: directory.appendingPathComponent(id).path
        )
    }

    private func readOpencodeJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.opencodeConfig)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeOpencodeJSON(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: paths.opencodeConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: paths.opencodeConfig)
    }

    // MARK: - The target table

    /// Two directories, four agents. The overlap is deliberate, so it is
    /// asserted rather than left to be rediscovered as a bug.
    func testTwoTargetsCoverFourAgents() {
        let targets = SkillBinder.nativeTargets(paths: paths)

        XCTAssertEqual(
            targets.map(\.directory),
            [paths.claudeSkills, paths.agentsSkills],
            "the native directories changed, and the plan's table is written against these two"
        )
        XCTAssertEqual(
            Set(targets.flatMap(\.agentIDs)),
            ["claude", "codex", "gemini", "opencode"],
            "a native target that no agent reads is a link written into a directory nothing scans"
        )
        XCTAssertEqual(
            targets.filter { $0.agentIDs.contains("opencode") }.count,
            2,
            "opencode scans both directories, so it is listed under both — the collision that "
                + "comes with that is known and is why the content has to be identical"
        )
    }

    /// Every id in the table has to name an agent that exists, or the report
    /// silently attaches its notes to nobody.
    func testEveryTargetNamesARealAgent() {
        let known = Set(AgentRegistry.builtIns.map(\.id))
        for target in SkillBinder.nativeTargets(paths: paths) {
            for id in target.agentIDs {
                XCTAssertTrue(known.contains(id), "\(id) is not an agent")
            }
        }
    }

    /// The reason this is a test rather than a comment: pre-creating either
    /// directory converts a host symlink into a real directory, silently, and
    /// duplicates whatever it pointed at. `createDirectories` runs on every
    /// sandbox preparation, so the mistake would be made constantly.
    func testNeitherNativeDirectoryIsCreatedEagerly() {
        for target in SkillBinder.nativeTargets(paths: paths) {
            XCTAssertFalse(
                paths.requiredDirectories.contains(target.directory),
                "\(target.directory.lastPathComponent) is pre-created, which would clobber a host symlink"
            )
        }
    }

    // MARK: - Linking

    func testASkillIsLinkedIntoBothNativeDirectories() throws {
        let release = skill()
        _ = try apply([release])

        let source = SkillStore.skillDirectory(id: release.id, paths: paths).path
        for target in SkillBinder.nativeTargets(paths: paths) {
            XCTAssertEqual(
                linkTarget(release.id, in: target.directory),
                source,
                "\(target.label) did not get a link"
            )
        }
    }

    /// One link, several readers. A report that mentioned the link under only
    /// one of them would read as though the others had been skipped.
    func testTheLinkIsReportedUnderEveryAgentThatReadsIt() throws {
        let reports = try apply([skill()])

        for agentID in ["claude", "codex", "gemini", "opencode"] {
            let lines = try notes(for: agentID, in: reports)
            XCTAssertTrue(
                lines.contains { $0.contains("skill discovery") },
                "\(agentID) reads a native directory but its report says nothing about it"
            )
        }
    }

    func testDisablingASkillRemovesItsLinks() throws {
        let release = skill()
        _ = try apply([release])
        _ = try apply([])

        for target in SkillBinder.nativeTargets(paths: paths) {
            XCTAssertNil(
                linkTarget(release.id, in: target.directory),
                "a disabled skill is still linked into \(target.label)"
            )
        }
    }

    // MARK: - Refusals

    /// The failure this whole file exists to prevent: a skill that is present,
    /// linked correctly, and never loaded, with every visible signal saying it
    /// worked.
    func testAReservedNameIsRefusedRatherThanLinked() throws {
        let reserved = skill(id: "synced", name: "Synced")
        let reports = try apply([reserved])

        for target in SkillBinder.nativeTargets(paths: paths) {
            XCTAssertNil(
                linkTarget("synced", in: target.directory),
                "a reserved name was linked into \(target.label)"
            )
        }

        let lines = try notes(for: "claude", in: reports)
        XCTAssertTrue(
            lines.contains { $0.contains("refused to link synced") },
            "the refusal was silent: \(lines)"
        )
    }

    /// An absent description is not a missing one.
    ///
    /// `rendered()` writes the display name in place of an absent summary, so
    /// the file that lands on disk says `description: Blank` and every agent
    /// loads it. This used to be refused as *blocking* — "no description" — and
    /// that was wrong twice over: no agent rejects the file, and the same skill
    /// reported only an advisory once the store had read it back off disk.
    /// `jxcode skill-add` therefore called a skill blocking that `jxcode
    /// skill-check` called fine, in the same run, about the same bytes.
    ///
    /// The refusal is gone and the warning stays. Linking is the truthful
    /// claim now, because a bind says the agent will find the skill and it will.
    func testASkillWithNoDescriptionIsLinkedAndWarnedAbout() throws {
        let empty = skill(id: "blank", name: "Blank", summary: "", body: "   ")
        XCTAssertFalse(
            empty.findings.contains { $0.severity == .blocking },
            "a file no agent rejects is not a blocking finding"
        )
        XCTAssertTrue(
            empty.findings.contains { $0.severity == .advisory },
            "the author still has to be told the description is the name"
        )

        let reports = try apply([empty])

        XCTAssertNotNil(linkTarget("blank", in: paths.agentsSkills))
        XCTAssertFalse(
            try notes(for: "codex", in: reports).contains { $0.contains("refused") },
            "the file loads, so nothing was refused"
        )
    }

    /// Advisory findings are worth saying and not worth refusing over. The
    /// description repeating the name is the common mistake, and blocking it
    /// would make the binder refuse a skill that loads perfectly well.
    func testASkillWithOnlyAdvisoryFindingsIsStillLinked() throws {
        let repeats = skill(id: "tidy", name: "Tidy", summary: "Tidy")
        XCTAssertFalse(repeats.findings.contains { $0.severity == .blocking })

        _ = try apply([repeats])
        XCTAssertNotNil(linkTarget("tidy", in: paths.agentsSkills))
    }

    // MARK: - opencode's permission gate

    func testTheSkillPermissionIsWrittenInTheSamePassAsTheLink() throws {
        _ = try apply([skill()])

        let root = try readOpencodeJSON()
        let permission = try XCTUnwrap(root["permission"] as? [String: Any])
        let skill = try XCTUnwrap(permission["skill"] as? [String: Any])
        XCTAssertEqual(skill["*"] as? String, "allow")
        XCTAssertTrue(SkillBinder.readManifest(paths: paths).opencodeSkillPermission)
    }

    func testThePermissionIsReportedUnderOpencodeOnly() throws {
        let reports = try apply([skill()])

        XCTAssertTrue(
            try notes(for: "opencode", in: reports)
                .contains { $0.contains("permission.skill") },
            "the one agent the gate applies to was not told about it"
        )
        XCTAssertFalse(
            try notes(for: "codex", in: reports).contains { $0.contains("permission.skill") },
            "codex does not read opencode.json"
        )
    }

    /// A bind is not a licence to change a permission the user set. Reporting
    /// it and leaving it is the only honest answer.
    func testAnExistingSkillPermissionIsNotOverruled() throws {
        try writeOpencodeJSON(["permission": ["skill": ["*": "deny"]]])

        let reports = try apply([skill()])

        let root = try readOpencodeJSON()
        let permission = try XCTUnwrap(root["permission"] as? [String: Any])
        let skill = try XCTUnwrap(permission["skill"] as? [String: Any])
        XCTAssertEqual(skill["*"] as? String, "deny", "the bind overruled the user's own setting")
        XCTAssertTrue(
            try notes(for: "opencode", in: reports).contains { $0.contains("does not overrule") }
        )
        XCTAssertFalse(
            SkillBinder.readManifest(paths: paths).opencodeSkillPermission,
            "nothing was written, so nothing is ours to take back"
        )
    }

    func testTheUsersOtherOpencodeSettingsSurvive() throws {
        try writeOpencodeJSON([
            "theme": "tokyonight",
            "permission": ["edit": "ask", "bash": ["*": "deny"]],
        ])

        _ = try apply([skill()])

        let root = try readOpencodeJSON()
        XCTAssertEqual(root["theme"] as? String, "tokyonight")
        let permission = try XCTUnwrap(root["permission"] as? [String: Any])
        XCTAssertEqual(permission["edit"] as? String, "ask")
        XCTAssertNotNil(permission["bash"])
        XCTAssertEqual((permission["skill"] as? [String: Any])?["*"] as? String, "allow")
    }

    /// Replacing a file we cannot parse deletes whatever is in it. The same
    /// rule `ConnectorBinder` applies, for the same reason.
    func testAnOpencodeConfigThatIsNotAnObjectIsLeftAlone() throws {
        try FileManager.default.createDirectory(
            at: paths.opencodeConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "[this is not json]\n"
        try original.write(to: paths.opencodeConfig, atomically: true, encoding: .utf8)

        let reports = try apply([skill()])

        XCTAssertEqual(try String(contentsOf: paths.opencodeConfig, encoding: .utf8), original)
        XCTAssertTrue(
            try notes(for: "opencode", in: reports).contains { $0.contains("not a JSON object") }
        )
    }

    // MARK: - Revert

    /// Every directory a bind may create, in one place, so a new writer that
    /// forgets to register one is a failing test rather than a survivor found
    /// months later.
    private var bindCreatedDirectories: [URL] {
        [paths.claudeSkills, paths.agentsSkills, paths.agentsHome, paths.opencodeHome]
    }

    /// A bind with nothing to bind must make nothing exist.
    ///
    /// It used to create `.claude/skills/`, `.agents/skills/` and
    /// `.config/opencode/`, write an `opencode.json` granting opencode a skill
    /// permission, and leave a manifest recording the grant — while printing
    /// "no shared skills to list" and "0 linked" beside all of it. A bind that
    /// binds nothing has to be a no-op, not a first write.
    func testAnEmptyBindCreatesNoDirectory() throws {
        let fm = FileManager.default

        _ = try apply([])

        for directory in bindCreatedDirectories {
            XCTAssertFalse(
                fm.fileExists(atPath: directory.path),
                "an empty bind created \(directory.path)"
            )
        }
        XCTAssertFalse(fm.fileExists(atPath: paths.opencodeConfig.path),
                       "an empty bind wrote a config file to hold a grant it had no reason to make")
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedSkillsManifest.path),
                       "an empty bind recorded a permission it never granted")
    }

    /// The directory half of "revert removes what it created".
    ///
    /// The count is asserted rather than the presence of each, because the
    /// interesting number is *four*: the README named two directories as the
    /// ones that survive, and the two it did not name were invisible because
    /// `createDirectory` makes every missing ancestor without reporting them.
    func testRevertRemovesTheDirectoriesTheBindCreated() throws {
        let fm = FileManager.default
        _ = try apply([skill()])
        for directory in bindCreatedDirectories {
            XCTAssertTrue(fm.fileExists(atPath: directory.path),
                          "\(directory.path) should exist after binding")
        }

        let messages = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        for directory in bindCreatedDirectories {
            XCTAssertFalse(fm.fileExists(atPath: directory.path),
                           "revert left \(directory.path) behind")
        }
        XCTAssertEqual(
            messages.filter { $0.contains("an empty directory the bind created") }.count,
            4,
            "each removal is reported once — got \(messages)"
        )
    }

    /// A directory that predated the bind is not ours to take away, whichever
    /// bind created the *files* in it.
    func testRevertKeepsASkillDirectoryTheUserAlreadyHad() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.agentsSkills, withIntermediateDirectories: true)

        _ = try apply([skill()])
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertTrue(fm.fileExists(atPath: paths.agentsSkills.path),
                      "the directory predated the bind, so the unbind must leave it")
        XCTAssertTrue(fm.fileExists(atPath: paths.agentsHome.path))
        XCTAssertFalse(fm.fileExists(atPath: paths.claudeSkills.path),
                       "and the one it did create should still go")
    }

    /// "Empty" and "ours" are two different questions, and the marker only
    /// answers the second.
    func testRevertKeepsACreatedDirectoryThatGainedUserContent() throws {
        let fm = FileManager.default
        _ = try apply([skill()])
        let theirs = paths.agentsSkills.appendingPathComponent("their-own-skill")
        try "theirs".write(to: theirs, atomically: true, encoding: .utf8)

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertTrue(fm.fileExists(atPath: theirs.path),
                      "the unbind deleted the user's own skill along with our container")
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "theirs")
    }

    /// The grant and the links go on together and come off together — including
    /// when the bind that follows has nothing to link.
    func testAnEmptyBindTakesBackTheGrantTheFirstOneMade() throws {
        let fm = FileManager.default
        _ = try apply([skill()])
        XCTAssertTrue(fm.fileExists(atPath: paths.opencodeConfig.path))
        XCTAssertTrue(SkillBinder.readManifest(paths: paths).opencodeSkillPermission)

        let reports = try apply([])

        XCTAssertFalse(
            fm.fileExists(atPath: paths.opencodeConfig.path),
            "a file whose only content was our grant should go when there is nothing to allow"
        )
        XCTAssertFalse(SkillBinder.readManifest(paths: paths).opencodeSkillPermission)
        // Hoisted out of the assertion: an `XCTAssert*` argument is an
        // autoclosure, so a throwing call cannot live inside one.
        let opencodeNotes = try notes(for: "opencode", in: reports)
        XCTAssertTrue(
            opencodeNotes.contains { $0.contains("removed opencode's shared-skill permission") },
            "the revoke is reported, not silent — got \(opencodeNotes)"
        )
    }

    func testRevertUnlinksEveryNativeDirectory() throws {
        let release = skill()
        _ = try apply([release])
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        for target in SkillBinder.nativeTargets(paths: paths) {
            XCTAssertNil(
                linkTarget(release.id, in: target.directory),
                "revert left a link in \(target.label)"
            )
        }
    }

    func testRevertTakesBackThePermissionItAdded() throws {
        try writeOpencodeJSON(["theme": "tokyonight"])
        _ = try apply([skill()])
        XCTAssertEqual((try readOpencodeJSON()["permission"] as? [String: Any])?.count, 1)

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        let root = try readOpencodeJSON()
        XCTAssertNil(root["permission"], "revert left a permission entry behind")
        XCTAssertEqual(root["theme"] as? String, "tokyonight")
        XCTAssertFalse(SkillBinder.readManifest(paths: paths).opencodeSkillPermission)
    }

    /// The reason the manifest exists. `"*": "allow"` written by the user and
    /// `"*": "allow"` written by JXCode are the same bytes, so an unbind that
    /// keyed off the value would revoke a permission it never granted.
    func testRevertDoesNotRevokeAPermissionTheUserSetThemselves() throws {
        try writeOpencodeJSON(["permission": ["skill": ["*": "allow"]]])

        _ = try apply([skill()])
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        let root = try readOpencodeJSON()
        let permission = try XCTUnwrap(root["permission"] as? [String: Any])
        let skill = try XCTUnwrap(permission["skill"] as? [String: Any])
        XCTAssertEqual(skill["*"] as? String, "allow", "revert revoked the user's own permission")
    }

    /// Reverting means putting the tree back how it was found. A file whose
    /// only content was our permission entry did not exist before the bind, so
    /// it should not exist after the unbind either — and neither should a
    /// record whose only content is that nothing is bound.
    func testRevertRemovesTheFilesItCreated() throws {
        let fm = FileManager.default
        _ = try apply([skill()])
        XCTAssertTrue(fm.fileExists(atPath: paths.opencodeConfig.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.sharedSkillsManifest.path))

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertFalse(
            fm.fileExists(atPath: paths.opencodeConfig.path),
            "revert left an empty opencode.json behind"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: paths.sharedSkillsManifest.path),
            "revert left a manifest whose only content is that nothing is bound"
        )
    }

    /// The bug `ConfigFiles` exists to prevent, and the reason it is one shared
    /// rule rather than four private copies.
    ///
    /// `opencode.json` is written by two binders. The skill pass creates it; the
    /// connector pass then finds it and used to back it up — recording the
    /// **user** as the author of a file JXCode wrote. Revert then declined to
    /// delete a file that was entirely ours and left `{}` where there should be
    /// nothing. The same shape of bug lives in every instruction file, which
    /// `SkillBinder` and `SystemPrompt` both write.
    func testASecondBinderDoesNotClaimTheFirstBindersFile() throws {
        let fm = FileManager.default
        _ = try apply([skill()])
        _ = try ConnectorBinder.apply(
            connectors: [connector()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        XCTAssertFalse(
            fm.fileExists(atPath: ConfigFiles.backupURL(of: paths.opencodeConfig).path),
            "the connector pass backed up a file JXCode created, which claims the user wrote it"
        )

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)
        _ = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertFalse(
            fm.fileExists(atPath: paths.opencodeConfig.path),
            "revert left an empty opencode.json behind"
        )
    }

    /// The marker is the record that we made the file, so it has to go when the
    /// file does — otherwise the next writer at that path inherits the claim,
    /// and a file the user wrote by hand is later deleted as ours.
    func testTheCreationRecordDoesNotOutliveTheFile() throws {
        let file = paths.opencodeConfig
        _ = try apply([skill()])
        XCTAssertTrue(ConfigFiles.isCreated(byJXCode: file))

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ConfigFiles.createdURL(of: file).path),
            "the marker outlived the file it describes"
        )
    }

    /// A file the user had first is never deleted, however empty it ends up.
    func testAFileTheUserHadFirstIsNeverDeleted() throws {
        try writeOpencodeJSON(["permission": ["skill": ["*": "deny"]]])

        _ = try apply([skill()])
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.opencodeConfig.path),
            "revert deleted a file the user wrote"
        )
        XCTAssertFalse(ConfigFiles.isCreated(byJXCode: paths.opencodeConfig))
    }

    // MARK: - Validation on write

    func testAReservedNameCannotBeWrittenAtAll() throws {
        let store = SharedStore(paths: paths)

        XCTAssertThrowsError(try store.writeSkill(skill(id: "synced", name: "Synced"))) { error in
            guard case SharedStoreError.unusableSkill(let id, _) = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
            XCTAssertEqual(id, "synced")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: SkillStore.skillFile(id: "synced", paths: paths).path
            ),
            "the refusal happened after the file was written"
        )
    }

    /// `isSafePathComponent` keeps letters and digits, and `é` is a letter, so
    /// this id passes the path check and fails the specification. It is the
    /// first thing a non-English author types.
    func testANameThatIsNotSpecCompliantCannotBeWritten() throws {
        let store = SharedStore(paths: paths)

        XCTAssertThrowsError(
            try store.writeSkill(skill(id: "café", name: "Café checklist"))
        ) { error in
            guard case SharedStoreError.unusableSkill = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
    }

    func testAnOverlongDescriptionCannotBeWritten() throws {
        let store = SharedStore(paths: paths)
        let long = String(repeating: "a", count: SkillSpec.maxDescriptionLength + 1)

        XCTAssertThrowsError(try store.writeSkill(skill(summary: long))) { error in
            guard case SharedStoreError.unusableSkill = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
    }

    /// The check runs against the rendered text, not the value. `rendered()`
    /// writes the id into `name:` and always writes a description, so an absent
    /// summary is *repaired* on the way out rather than refused — which is what
    /// keeps `jxcode skill-add --name X` working without a `--description`.
    ///
    /// The repair is the display name, so the file it produces carries the one
    /// description that cannot help: one advisory, and no blocking finding,
    /// because the file loads.
    func testAnAbsentDescriptionIsRepairedRatherThanRefused() throws {
        let store = SharedStore(paths: paths)
        let written = try store.writeSkill(skill(summary: ""))

        let text = try String(
            contentsOf: SkillStore.skillFile(id: written.id, paths: paths),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("description: Release checklist"), text)

        let findings = SkillSpec.findings(id: written.id, text: text)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .advisory)
    }

    func testAWrittenSkillPassesTheSpecificationTheAgentsApply() throws {
        let store = SharedStore(paths: paths)
        let written = try store.writeSkill(skill())

        let text = try String(
            contentsOf: SkillStore.skillFile(id: written.id, paths: paths),
            encoding: .utf8
        )
        XCTAssertEqual(
            SkillSpec.findings(id: written.id, text: text).filter { $0.severity == .blocking },
            [],
            "the store wrote a file its own validator rejects"
        )
        XCTAssertTrue(written.isBindableNatively)
    }

    /// The reserved check lives on the id, so both checkers have to agree about
    /// it — the one that judges a value and the one that judges a file.
    func testBothCheckersAgreeThatAReservedNameIsBlocking() {
        let reserved = skill(id: "anthropic-skills:pdf", name: "PDF")
        XCTAssertTrue(reserved.findings.contains { $0.severity == .blocking })

        let text = """
        ---
        name: anthropic-skills:pdf
        description: Reads PDFs
        ---

        Body.
        """
        XCTAssertTrue(
            SkillSpec.findings(id: "anthropic-skills:pdf", text: text)
                .contains { $0.severity == .blocking }
        )
    }

    /// The invariant the reserved-name case above is one instance of: for a
    /// skill JXCode itself wrote, the two checkers have to reach the same
    /// verdict.
    ///
    /// They judge different things by design — the value check cannot see a
    /// misplaced frontmatter fence, and the file check cannot see a path-unsafe
    /// id — so a blanket "the findings are equal" test would be wrong. What has
    /// to hold is that the bytes the store *writes* are judged the same as the
    /// value it holds, because two different commands read those two views in
    /// the same run and a user who sees them disagree cannot tell which is
    /// right.
    func testTheTwoCheckersAgreeAboutASkillThatWasJustWritten() throws {
        let store = SharedStore(paths: paths)
        let written = try store.writeSkill(skill(summary: ""))

        let text = try String(
            contentsOf: SkillStore.skillFile(id: written.id, paths: paths),
            encoding: .utf8
        )
        let fromValue = written.findings
        let fromFile = SkillSpec.findings(id: written.id, text: text)

        XCTAssertEqual(fromValue.count, 1,
                       "one problem, not two: the value and the file are the same problem")
        XCTAssertEqual(fromFile.count, 1)
        XCTAssertEqual(fromValue.map(\.severity), fromFile.map(\.severity))
        XCTAssertEqual(fromValue.map(\.message), fromFile.map(\.message))
        XCTAssertFalse(fromValue.contains { $0.severity == .blocking })
    }

    /// A description copied from the body's title is the same mistake as one
    /// copied from the frontmatter name, and the file check used to miss it.
    ///
    /// The frontmatter `name` is the id, because the specification requires it
    /// to match the directory, and the human-readable title lives in the body's
    /// first heading — which is where `rendered()` puts it. Comparing the
    /// description against the frontmatter alone therefore never fired for the
    /// exact file `jxcode skill-add --name "Release checklist"` writes, so
    /// `jxcode skill-check` called it "loads everywhere" while `jxcode shared`
    /// said no agent would ever choose it.
    func testTheFileCheckerCatchesADescriptionCopiedFromTheTitle() {
        let text = """
        ---
        name: release-checklist
        description: Release checklist
        ---

        # Release checklist

        Run the suite.
        """
        let findings = SkillSpec.findings(id: "release-checklist", text: text)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .advisory)
    }

    /// The control: equality, not containment.
    ///
    /// "Use before tagging a release" contains the word the skill is named
    /// after and is a good description. A containment test would flag it, and a
    /// guardrail that fires on good input is one an author learns to ignore —
    /// the same lesson the reserved-name rule is written around.
    func testADescriptionThatOnlyMentionsTheNameIsNotFlagged() {
        let text = """
        ---
        name: release
        description: Use before tagging a release
        ---

        # Release

        Run the suite.
        """
        XCTAssertTrue(SkillSpec.findings(id: "release", text: text).isEmpty)
    }
}
