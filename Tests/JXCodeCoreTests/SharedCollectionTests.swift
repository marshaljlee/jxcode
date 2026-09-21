import XCTest
@testable import JXCodeCore

/// The shared collection: the store, the two binders, and the schedule.
///
/// These had no tests, which was the wrong way round — the schedule decides
/// when an agent actually runs unattended, and "it ran at the wrong time" is
/// the one failure a user would notice immediately. Everything here is pure or
/// filesystem-bound, so none of it needs a clock, a process, or a network.
final class SharedCollectionTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!
    private var sandbox: Sandbox!

    /// Fixed, so the weekday-dependent cases do not move with the machine's
    /// locale or time zone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        sandbox = Sandbox(paths: paths)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    /// Saturday, 19 September 2026. Asserted in its own test below, because
    /// every weekly case is written against it.
    private var saturday: Date { at(2026, 9, 19, 12, 0) }
    private var sunday: Date { at(2026, 9, 20, 12, 0) }

    private func agent(_ id: String) throws -> AgentDefinition {
        try XCTUnwrap(AgentRegistry.builtIns.first { $0.id == id })
    }

    private func skill(id: String = "release", name: String = "Release checklist") -> Skill {
        Skill(id: id, name: name, summary: "Steps before tagging", body: "# Release\n\nRun the suite.")
    }

    private func connector(id: String = "filesystem") -> Connector {
        Connector(
            id: id,
            name: "filesystem",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem"]
        )
    }

    // MARK: - The fixture date

    func testTheFixtureDateIsASaturday() {
        XCTAssertEqual(calendar.component(.weekday, from: saturday), 7,
                       "every weekly case below assumes 19 September 2026 is a Saturday")
        XCTAssertEqual(calendar.component(.weekday, from: sunday), 1)
    }

    // MARK: - Identifier

    func testSlugIsFilesystemSafeAndCollapsesRuns() {
        XCTAssertEqual(Identifier.slug("Release checklist"), "release-checklist")
        XCTAssertEqual(Identifier.slug("  Nightly   triage!! "), "nightly-triage")
        XCTAssertEqual(Identifier.slug("v2.0 — cut"), "v2-0-cut")
    }

    /// An id is a key and a directory name. An empty one is not usable as
    /// either, so an input with nothing alphanumeric in it has to fall back.
    func testSlugFallsBackWhenNothingUsableRemains() {
        XCTAssertEqual(Identifier.slug("!!!", fallback: "skill"), "skill")
        XCTAssertEqual(Identifier.slug("", fallback: "connector"), "connector")
    }

    // MARK: - Schedule: interval

    func testAnIntervalAutomationRunsImmediatelyWhenItHasNeverRun() {
        let schedule = AutomationSchedule(cadence: .interval, intervalMinutes: 60)
        XCTAssertTrue(schedule.isDue(last: nil, now: saturday, calendar: calendar))
    }

    func testAnIntervalAutomationWaitsOutItsInterval() {
        let schedule = AutomationSchedule(cadence: .interval, intervalMinutes: 60)
        let last = saturday.addingTimeInterval(-30 * 60)

        XCTAssertFalse(schedule.isDue(last: last, now: saturday, calendar: calendar))
        XCTAssertFalse(
            schedule.isDue(last: saturday.addingTimeInterval(-59 * 60), now: saturday, calendar: calendar)
        )
    }

    func testAnIntervalAutomationIsDueOnceItsIntervalHasElapsed() {
        let schedule = AutomationSchedule(cadence: .interval, intervalMinutes: 60)
        let last = saturday.addingTimeInterval(-60 * 60)
        XCTAssertTrue(schedule.isDue(last: last, now: saturday, calendar: calendar))
    }

    /// A zero or negative interval would otherwise be due on every tick, which
    /// is a loop that starts an agent as fast as the scheduler can go.
    func testAnIntervalAutomationWithNoIntervalNeverRuns() {
        let schedule = AutomationSchedule(cadence: .interval, intervalMinutes: 0)
        XCTAssertFalse(schedule.isDue(last: nil, now: saturday, calendar: calendar))
        XCTAssertFalse(schedule.isDue(last: saturday, now: saturday, calendar: calendar))
    }

    // MARK: - Schedule: daily

    func testADailyAutomationBeforeItsTimeIsNotDue() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 9, minute: 0)
        XCTAssertFalse(schedule.isDue(last: nil, now: at(2026, 9, 19, 8, 59), calendar: calendar))
    }

    /// There is no earlier anchor to compare against, so a never-run daily
    /// automation is due as soon as today's time has passed. The alternative —
    /// waiting for tomorrow — means it can never become due at all, because
    /// nothing else would ever set `last`.
    func testADailyAutomationThatHasNeverRunIsDueOnceTodaysTimeHasPassed() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 9, minute: 0)
        XCTAssertTrue(schedule.isDue(last: nil, now: at(2026, 9, 19, 14, 0), calendar: calendar))
    }

    func testADailyAutomationThatAlreadyRanTodayIsNotDue() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 9, minute: 0)
        let last = at(2026, 9, 19, 9, 0)
        XCTAssertFalse(schedule.isDue(last: last, now: at(2026, 9, 19, 14, 0), calendar: calendar))
    }

    func testADailyAutomationThatLastRanYesterdayIsDue() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 9, minute: 0)
        let last = at(2026, 9, 18, 9, 0)
        XCTAssertTrue(schedule.isDue(last: last, now: at(2026, 9, 19, 9, 0), calendar: calendar))
    }

    /// The boundary is `>=`, so an automation scheduled for exactly now is due.
    func testADailyAutomationScheduledForThisExactMinuteIsDue() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 9, minute: 0)
        XCTAssertTrue(schedule.isDue(last: nil, now: at(2026, 9, 19, 9, 0), calendar: calendar))
    }

    func testAnOutOfRangeHourIsClampedRatherThanCrashing() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 99, minute: -5)
        // Clamped to 23:00, so noon is not yet due — and, more to the point,
        // asking did not trap.
        XCTAssertFalse(schedule.isDue(last: nil, now: saturday, calendar: calendar))
    }

    // MARK: - Schedule: weekly

    func testAWeeklyAutomationIgnoresEveryOtherDay() {
        // weekday 2 == Monday; 19 September 2026 is a Saturday.
        let schedule = AutomationSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 2)
        XCTAssertFalse(schedule.isDue(last: nil, now: saturday, calendar: calendar))
    }

    func testAWeeklyAutomationRunsOnItsOwnDay() {
        // weekday 7 == Saturday.
        let schedule = AutomationSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 7)
        XCTAssertTrue(schedule.isDue(last: nil, now: saturday, calendar: calendar))
    }

    func testAWeeklyAutomationThatAlreadyRanOnItsDayIsNotDue() {
        let schedule = AutomationSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 7)
        let last = at(2026, 9, 19, 9, 30)
        XCTAssertFalse(schedule.isDue(last: last, now: saturday, calendar: calendar))
    }

    func testAWeeklyAutomationThatLastRanAWeekAgoIsDue() {
        let schedule = AutomationSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 7)
        let last = at(2026, 9, 12, 9, 0)
        XCTAssertTrue(schedule.isDue(last: last, now: saturday, calendar: calendar))
    }

    // MARK: - Schedule summaries

    func testTheScheduleSummariesReadAsSentences() {
        XCTAssertEqual(
            AutomationSchedule(cadence: .daily, hour: 9, minute: 0).summary,
            "Every day at 09:00"
        )
        XCTAssertEqual(
            AutomationSchedule(cadence: .weekly, hour: 18, minute: 5, weekday: 2).summary,
            "Every Monday at 18:05"
        )
        XCTAssertEqual(
            AutomationSchedule(cadence: .interval, intervalMinutes: 60).summary,
            "Every hour"
        )
        XCTAssertEqual(
            AutomationSchedule(cadence: .interval, intervalMinutes: 720).summary,
            "Every 12 hours"
        )
        XCTAssertEqual(
            AutomationSchedule(cadence: .interval, intervalMinutes: 90).summary,
            "Every 90 minutes"
        )
    }

    // MARK: - Skill parsing

    func testASkillRoundTripsThroughItsFile() throws {
        let original = Skill(
            id: "release",
            name: "Release checklist",
            summary: "Steps to run before tagging: a release",
            body: "# Release checklist\n\n- [ ] Suite green\n- [ ] Changelog"
        )

        let reloaded = Skill.parse(
            id: original.id,
            text: original.rendered(),
            enabled: true,
            updatedAt: original.updatedAt
        )

        XCTAssertEqual(reloaded.name, original.name)
        XCTAssertEqual(reloaded.summary, original.summary,
                       "a summary containing ': ' has to be quoted and unquoted again")
        XCTAssertEqual(reloaded.body, original.body)
    }

    func testASkillWithoutFrontmatterFallsBackToItsHeadingAndFirstParagraph() {
        let skill = Skill.parse(
            id: "house-style",
            text: "# House style\n\nPrefer explicit over clever.\n\n## Details\n\nMore.",
            enabled: true,
            updatedAt: Date()
        )

        XCTAssertEqual(skill.name, "House style")
        XCTAssertEqual(skill.summary, "Prefer explicit over clever.")
        XCTAssertEqual(skill.body, "# House style\n\nPrefer explicit over clever.\n\n## Details\n\nMore.")
    }

    /// An unterminated fence must not swallow the file. A skill whose content
    /// vanished is worse than one whose frontmatter did.
    func testAnUnterminatedFenceLeavesTheBodyIntact() {
        let skill = Skill.parse(
            id: "broken",
            text: "---\nname: Broken\n\n# Still here",
            enabled: true,
            updatedAt: Date()
        )
        XCTAssertTrue(skill.body.contains("# Still here"))
    }

    /// A skill written on Windows, or by an editor set to CRLF, must come back
    /// that way — the body is the user's, and rewriting it is the same bug as
    /// rewriting an `AGENTS.md`.
    func testACRLFSkillKeepsItsLineEndings() {
        let text = "---\r\nname: Demo\r\ndescription: A demo\r\n---\r\n\r\n# Demo\r\n\r\nBody text.\r\n"
        let skill = Skill.parse(id: "demo", text: text, enabled: true, updatedAt: at(2026, 9, 21, 9, 0))

        XCTAssertEqual(skill.name, "Demo")
        XCTAssertEqual(skill.summary, "A demo")
        XCTAssertTrue(skill.body.contains("\r\n"), "the body lost its CRLF")

        let rendered = skill.rendered()
        XCTAssertFalse(
            rendered.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
            "the rendered skill mixes terminators: \(rendered.debugDescription)"
        )
        XCTAssertEqual(
            Skill.parse(id: "demo", text: rendered, enabled: true, updatedAt: at(2026, 9, 21, 9, 0)).body,
            skill.body
        )
    }

    // MARK: - The store

    func testWritingASkillCreatesItsFileAndSidecar() throws {
        let store = SharedStore(paths: paths)
        try store.writeSkill(skill())

        let file = SkillStore.skillFile(id: "release", paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SkillStore.skillDirectory(id: "release", paths: paths)
                .appendingPathComponent("skill.json").path
        ))
    }

    func testAWrittenSkillIsVisibleToAFreshStore() throws {
        try SharedStore(paths: paths).writeSkill(skill())

        let reopened = SharedStore(paths: paths)
        XCTAssertEqual(reopened.skills.map(\.id), ["release"])
        XCTAssertEqual(reopened.skills.first?.name, "Release checklist")
    }

    func testDisablingASkillKeepsItButDropsItFromTheEnabledSet() throws {
        let store = SharedStore(paths: paths)
        try store.writeSkill(skill())
        try store.setSkillEnabled(id: "release", enabled: false)

        XCTAssertEqual(store.skills.count, 1, "switching a skill off must not delete it")
        XCTAssertTrue(store.enabledSkills.isEmpty)
        XCTAssertFalse(SharedStore(paths: paths).skills.first?.enabled ?? true,
                       "the off state has to survive a reload, or it only lasts one session")
    }

    func testRemovingASkillDeletesItsDirectory() throws {
        let store = SharedStore(paths: paths)
        try store.writeSkill(skill())
        try store.removeSkill(id: "release")

        XCTAssertTrue(store.skills.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SkillStore.skillDirectory(id: "release", paths: paths).path
        ))
    }

    func testSkillsAreSortedByIdSoTheUIAndCLIAgree() throws {
        let store = SharedStore(paths: paths)
        try store.writeSkill(skill(id: "zebra", name: "Zebra"))
        try store.writeSkill(skill(id: "alpha", name: "Alpha"))

        XCTAssertEqual(store.skills.map(\.id), ["alpha", "zebra"])
    }

    func testConnectorsAndAutomationsRoundTrip() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(connector())
        try store.writeAutomation(Automation(
            id: "nightly",
            name: "Nightly triage",
            agentID: "claude",
            prompt: "triage open issues"
        ))

        let reopened = SharedStore(paths: paths)
        XCTAssertEqual(reopened.connectors.first?.id, "filesystem")
        XCTAssertEqual(reopened.connectors.first?.arguments,
                       ["-y", "@modelcontextprotocol/server-filesystem"])
        XCTAssertEqual(reopened.automations.first?.agentID, "claude")
        XCTAssertEqual(reopened.automations.first?.schedule.cadence, .daily)
    }

    func testRecordRunIsPersisted() throws {
        let store = SharedStore(paths: paths)
        try store.writeAutomation(Automation(
            id: "nightly", name: "Nightly", agentID: "claude", prompt: "go"
        ))

        let ranAt = at(2026, 9, 19, 9, 0)
        try store.recordRun(id: "nightly", at: ranAt, result: "ok: nothing to do")

        let reloaded = try XCTUnwrap(SharedStore(paths: paths).automations.first)
        XCTAssertEqual(reloaded.lastResult, "ok: nothing to do")
        XCTAssertEqual(reloaded.lastRun, ranAt)
    }

    // MARK: - SkillBinder

    // MARK: - Pruning

    /// The prune asked whether a link's destination *started with* the shared
    /// skills directory, so `…/shared/skills-archive` — a sibling, and exactly
    /// the sort of directory someone keeps archived skills in — answered yes
    /// and was deleted. The trailing slash is the whole difference.
    func testPruningLeavesASiblingOfTheSharedDirectoryAlone() throws {
        let fm = FileManager.default
        let archive = try makeSiblingOfSharedSkills()
        let link = paths.claudeSkills.appendingPathComponent("archive")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: archive.path)

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(
            try? fm.destinationOfSymbolicLink(atPath: link.path), archive.path,
            "a link to a sibling of the shared skills directory was deleted"
        )
    }

    /// The same decision is made again on revert, on a different path.
    func testRevertLeavesASiblingOfTheSharedDirectoryAlone() throws {
        let fm = FileManager.default
        let archive = try makeSiblingOfSharedSkills()
        let link = paths.claudeSkills.appendingPathComponent("archive")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: archive.path)

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(
            try? fm.destinationOfSymbolicLink(atPath: link.path), archive.path,
            "revert deleted a link to a sibling of the shared skills directory"
        )
    }

    /// The prune still has to work. A link of ours whose skill is gone is
    /// dangling, and leaving it is what makes a deleted skill still show up in
    /// Claude Code.
    func testAStaleLinkOfOursIsPruned() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.claudeSkills, withIntermediateDirectories: true)
        let gone = paths.sharedSkills.appendingPathComponent("gone", isDirectory: true)
        try fm.createDirectory(at: gone, withIntermediateDirectories: true)
        let link = paths.claudeSkills.appendingPathComponent("gone")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: gone.path)
        try fm.removeItem(at: gone)   // the skill was deleted out from under it

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertNil(
            try? fm.destinationOfSymbolicLink(atPath: link.path),
            "a stale link of ours was left behind"
        )
    }

    /// A link that points into the shared directory relatively is still ours.
    func testARelativeLinkIntoTheSharedDirectoryIsPruned() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.claudeSkills, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.sharedSkills, withIntermediateDirectories: true)
        let link = paths.claudeSkills.appendingPathComponent("relative")
        let target = paths.sharedSkills.appendingPathComponent("release", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // Resolved from the directory holding the link, not from wherever we
        // happen to be running — and pointed at a skill, not at the directory
        // itself, which is not inside itself.
        try fm.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: relativePath(from: paths.claudeSkills, to: target)
        )

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertNil(
            try? fm.destinationOfSymbolicLink(atPath: link.path),
            "a relative link into the shared directory was not recognised as ours"
        )
    }

    func testALinkToSomewhereElseEntirelyIsLeftAlone() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.claudeSkills, withIntermediateDirectories: true)
        let mine = root.appendingPathComponent("my-own-skills", isDirectory: true)
        try fm.createDirectory(at: mine, withIntermediateDirectories: true)
        let link = paths.claudeSkills.appendingPathComponent("mine")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: mine.path)

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: link.path), mine.path)
    }

    /// `…/shared/skills-archive`: the name that made the prefix test answer yes.
    private func makeSiblingOfSharedSkills() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.claudeSkills, withIntermediateDirectories: true)
        let archive = paths.shared.appendingPathComponent("skills-archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        return archive
    }

    /// `../../skills` — a link written the way a person would, not the way we
    /// write them.
    private func relativePath(from base: URL, to target: URL) -> String {
        var left = base.standardizedFileURL.pathComponents
        var right = target.standardizedFileURL.pathComponents
        while !left.isEmpty, left.first == right.first {
            left.removeFirst()
            right.removeFirst()
        }
        return String(repeating: "../", count: left.count) + right.joined(separator: "/")
    }

    func testBindingSkillsWritesAFencedBlockIntoEveryAgentThatReadsOne() throws {
        let reports = try SkillBinder.apply(
            skills: [skill()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        for id in ["claude", "codex", "gemini", "opencode"] {
            let report = try XCTUnwrap(reports.first { $0.agentID == id })
            XCTAssertEqual(report.action, .bound, "\(id) should accept shared skills")

            let file = try XCTUnwrap(SkillBinder.instructionFile(
                for: try agent(id), paths: paths
            ))
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains(ManagedBlock.Markers.markdownSkills.start))
            XCTAssertTrue(text.contains(ManagedBlock.Markers.markdownSkills.end))
            XCTAssertTrue(text.contains("Release checklist"))
        }
    }

    /// The block names each skill's *file*, not its text, so a skill stays one
    /// file on disk and editing it takes effect everywhere at once.
    func testTheBlockPointsAtTheSkillFileRatherThanInliningIt() throws {
        _ = try SkillBinder.apply(
            skills: [skill()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        let claude = try XCTUnwrap(SkillBinder.instructionFile(
            for: try agent("claude"), paths: paths
        ))
        let text = try String(contentsOf: claude, encoding: .utf8)
        XCTAssertTrue(text.contains(SkillStore.skillFile(id: "release", paths: paths).path))
        XCTAssertFalse(text.contains("Run the suite."), "the body must not be copied in")
    }

    /// `shared/` is a sibling of `env/`, so it is not under the `$HOME` an
    /// agent runs with. A relative path would resolve to nothing and the agent
    /// would report a missing file rather than a skill it could not find.
    func testTheBlockUsesAbsolutePaths() throws {
        _ = try SkillBinder.apply(
            skills: [skill()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        let claude = try XCTUnwrap(SkillBinder.instructionFile(
            for: try agent("claude"), paths: paths
        ))
        let text = try String(contentsOf: claude, encoding: .utf8)
        XCTAssertTrue(text.contains("`\(root.path)/shared/skills/release/SKILL.md`"))
    }

    func testAnAgentWithNoInstructionFileIsReportedRatherThanSilentlySkipped() throws {
        let reports = try SkillBinder.apply(
            skills: [skill()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        for id in ["omp", "jules", "shell"] {
            let report = try XCTUnwrap(reports.first { $0.agentID == id })
            XCTAssertEqual(report.action, .notApplicable)
            XCTAssertFalse(report.notes.isEmpty, "\(id) should say why it cannot be bound")
        }
    }

    /// An empty block is noise in a file the user reads, and it would make
    /// "skills are switched off" indistinguishable from "never configured".
    /// Here the file held nothing but our block, so it goes entirely.
    func testBindingNoSkillsRemovesTheBlockInsteadOfWritingItEmpty() throws {
        _ = try SkillBinder.apply(
            skills: [skill()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )
        _ = try SkillBinder.apply(skills: [], agents: AgentRegistry.builtIns, paths: paths)

        let claude = try XCTUnwrap(SkillBinder.instructionFile(
            for: try agent("claude"), paths: paths
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: claude.path),
            "nothing of the user's was in there, so the file goes rather than being left blank"
        )
    }

    func testHandWrittenTextAroundTheBlockSurvivesRebinding() throws {
        let claude = try XCTUnwrap(SkillBinder.instructionFile(
            for: try agent("claude"), paths: paths
        ))
        try FileManager.default.createDirectory(
            at: claude.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "# My own notes\n\nKeep me.\n".write(to: claude, atomically: true, encoding: .utf8)

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)
        _ = try SkillBinder.apply(skills: [], agents: AgentRegistry.builtIns, paths: paths)

        let text = try String(contentsOf: claude, encoding: .utf8)
        XCTAssertTrue(text.contains("Keep me."), "text outside the markers is not ours to touch")
    }

    /// A second run must not overwrite a good backup with an already-modified
    /// file — otherwise the backup stops being a record of the original.
    func testAFailedBindIsBackedUpOnlyOnce() throws {
        let claude = try XCTUnwrap(SkillBinder.instructionFile(
            for: try agent("claude"), paths: paths
        ))
        try FileManager.default.createDirectory(
            at: claude.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "# Original\n".write(to: claude, atomically: true, encoding: .utf8)

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)
        _ = try SkillBinder.apply(skills: [skill(id: "two", name: "Two")],
                                  agents: AgentRegistry.builtIns, paths: paths)

        let backup = claude.appendingPathExtension("jxcode-backup")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "# Original\n")
    }

    /// Stated as "no agent still lists them" rather than "the file is gone",
    /// so it holds whether the file was removed or kept for the user's own text.
    func testRevertRemovesTheBlockFromEveryAgent() throws {
        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        for id in ["claude", "codex", "gemini", "opencode"] {
            let file = try XCTUnwrap(SkillBinder.instructionFile(
                for: try agent(id), paths: paths
            ))
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertFalse(
                text.contains(ManagedBlock.Markers.markdownSkills.start),
                "\(id) still lists the shared skills"
            )
        }
    }

    // MARK: - ConnectorBinder

    func testEnabledConnectorsReachEveryAgentThatHasAnMCPConfig() throws {
        let reports = try ConnectorBinder.apply(
            connectors: [connector()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        for id in ["claude", "gemini", "opencode", "codex"] {
            let report = try XCTUnwrap(reports.first { $0.agentID == id })
            XCTAssertEqual(report.action, .bound, "\(id) should accept an MCP server")
        }

        let manifest = ConnectorBinder.readManifest(paths: paths)
        XCTAssertEqual(manifest.managed, ["filesystem"])
        XCTAssertEqual(manifest.mcpServers["filesystem"]?.command, "npx")
    }

    func testAnIncompleteConnectorIsRefusedOnceNotOncePerAgent() throws {
        let broken = Connector(id: "broken", name: "Broken", transport: .stdio, command: "")

        let reports = try ConnectorBinder.apply(
            connectors: [broken],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        let refusals = reports.filter { $0.action == .refused }
        XCTAssertEqual(refusals.count, 1, "one mistake, one line — not one per agent")
        XCTAssertEqual(refusals.first?.agentID, "connector.broken")
        XCTAssertTrue(refusals.first?.notes.first?.contains("no command") ?? false)
    }

    func testADisabledConnectorIsNotWritten() throws {
        var off = connector()
        off.enabled = false

        _ = try ConnectorBinder.apply(
            connectors: [off],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        XCTAssertTrue(ConnectorBinder.readManifest(paths: paths).managed.isEmpty)
    }

    func testAnAgentWithNoMCPClientIsReportedRatherThanSkipped() throws {
        let reports = try ConnectorBinder.apply(
            connectors: [connector()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )

        for id in ["omp", "jules", "shell"] {
            let report = try XCTUnwrap(reports.first { $0.agentID == id })
            XCTAssertEqual(report.action, .notApplicable)
            XCTAssertFalse(report.notes.isEmpty)
        }
    }

    /// Removing a connector has to take it back out of the agents, or the next
    /// launch of that agent starts a server the user deleted.
    func testRebindingWithoutAConnectorRemovesItFromTheAgents() throws {
        _ = try ConnectorBinder.apply(
            connectors: [connector()],
            agents: AgentRegistry.builtIns,
            paths: paths
        )
        _ = try ConnectorBinder.apply(connectors: [], agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertTrue(ConnectorBinder.readManifest(paths: paths).managed.isEmpty)

        // The file held nothing but our entry, so it is removed rather than
        // left behind as `{}`.
        let claudeMCP = (try? String(contentsOf: paths.claudeMCPFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(claudeMCP.contains("filesystem"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.claudeMCPFile.path))
    }

    // MARK: - AutomationRunner

    func testDueReturnsOnlyEnabledAutomationsThatAreDue() {
        let neverRun = Automation(
            id: "due", name: "Due", agentID: "claude", prompt: "go",
            schedule: AutomationSchedule(cadence: .interval, intervalMinutes: 60)
        )
        var switchedOff = Automation(
            id: "off", name: "Off", agentID: "claude", prompt: "go",
            schedule: AutomationSchedule(cadence: .interval, intervalMinutes: 60)
        )
        switchedOff.enabled = false

        let justRan = Automation(
            id: "recent", name: "Recent", agentID: "claude", prompt: "go",
            schedule: AutomationSchedule(cadence: .interval, intervalMinutes: 60),
            lastRun: saturday
        )

        let due = AutomationRunner.due(
            automations: [neverRun, switchedOff, justRan],
            now: saturday,
            calendar: calendar
        )

        XCTAssertEqual(due.map(\.id), ["due"])
    }

    func testDueIsSortedSoTheOrderDoesNotDependOnInsertion() {
        let automations = ["c", "a", "b"].map { id in
            Automation(
                id: id, name: id, agentID: "claude", prompt: "go",
                schedule: AutomationSchedule(cadence: .interval, intervalMinutes: 1)
            )
        }
        XCTAssertEqual(
            AutomationRunner.due(automations: automations, now: saturday).map(\.id),
            ["a", "b", "c"]
        )
    }

    func testOnlyTheAgentsWithADocumentedHeadlessModeGetAnInvocation() {
        let prompt = "triage open issues"

        XCTAssertEqual(
            AutomationRunner.nonInteractiveInvocation(
                agent: AgentRegistry.builtIns.first { $0.id == "claude" }!, prompt: prompt
            ),
            ["-p", prompt]
        )
        XCTAssertEqual(
            AutomationRunner.nonInteractiveInvocation(
                agent: AgentRegistry.builtIns.first { $0.id == "codex" }!, prompt: prompt
            ),
            ["exec", prompt]
        )
        XCTAssertEqual(
            AutomationRunner.nonInteractiveInvocation(
                agent: AgentRegistry.builtIns.first { $0.id == "opencode" }!, prompt: prompt
            ),
            ["run", prompt]
        )

        // Guessing a flag here is worse than refusing: an unrecognised one
        // drops the agent into its interactive TUI, which then blocks forever
        // waiting for input a scheduled run will never provide.
        for id in ["omp", "jules", "shell"] {
            XCTAssertNil(
                AutomationRunner.nonInteractiveInvocation(
                    agent: AgentRegistry.builtIns.first { $0.id == id }!, prompt: prompt
                ),
                "\(id) has no documented headless mode"
            )
        }
    }

    func testRunningAnAutomationForAnUnknownAgentFailsWithASentence() {
        let automation = Automation(
            id: "ghost", name: "Ghost", agentID: "does-not-exist", prompt: "go"
        )

        let result = AutomationRunner.run(
            automation,
            agents: AgentRegistry.builtIns,
            workspaces: [],
            sandbox: sandbox
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("does-not-exist"))
    }

    /// A run that failed and was not recorded would be retried on every tick
    /// forever, so the schedule would look like it was working while producing
    /// nothing.
    func testAFailedRunIsStillRecorded() throws {
        let store = SharedStore(paths: paths)
        try store.writeAutomation(Automation(
            id: "ghost", name: "Ghost", agentID: "does-not-exist", prompt: "go"
        ))

        _ = AutomationRunner.run(
            try XCTUnwrap(store.automations.first),
            agents: AgentRegistry.builtIns,
            workspaces: [],
            sandbox: sandbox,
            store: store,
            now: saturday
        )

        let reloaded = try XCTUnwrap(SharedStore(paths: paths).automations.first)
        XCTAssertEqual(reloaded.lastRun, saturday)
        XCTAssertTrue(reloaded.lastResult?.hasPrefix("failed:") ?? false)
    }

    // MARK: - Unbinding must leave the tree as it found it

    /// Every file the binders write to, for the sweep below.
    private var writtenConfigFiles: [URL] {
        [paths.claudeMCPFile, paths.geminiSettings, paths.opencodeConfig, paths.codexMCPFile]
    }

    private var writtenInstructionFiles: [URL] {
        [paths.claudeMemory, paths.codexMemory, paths.geminiMemory, paths.opencodeMemory]
    }

    /// Every file under the sandbox root, as paths relative to it, sorted.
    ///
    /// Sorted so a comparison is about the *set* of files rather than the order
    /// the filesystem happened to hand them back, which varies run to run.
    private func treeUnderRoot() -> [String] {
        let manager = FileManager.default
        guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var found: [String] = []
        for case let url as URL in walk {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            found.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return found.sorted()
    }

    /// Unbinding something that was never bound must be a no-op.
    ///
    /// It used to create `{}` in `.claude.json`, `settings.json` and
    /// `opencode.json` — three config files appearing in an agent's home
    /// directory as a side effect of pressing "Unbind" — and then report
    /// "cleared the shared connectors from" each one it had just created.
    /// Reverting has to put the sandbox back, not merely stop writing.
    ///
    /// The eight config and instruction files are the ones a user would think
    /// to check, but the claim in this test's name is stronger than that:
    /// nothing at all should appear. Snapshotting the whole tree is what makes
    /// the name honest — and it is how the shared ledger turned up, created by
    /// `revert` to record that it had nothing to forget.
    func testRevertingOnACleanSandboxCreatesNothing() throws {
        let before = treeUnderRoot()

        let messages = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        for file in writtenConfigFiles + writtenInstructionFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: file.path),
                "\(file.lastPathComponent) did not exist before, so reverting must not create it"
            )
        }
        XCTAssertEqual(treeUnderRoot(), before,
                       "reverting on a clean sandbox must leave the tree exactly as it found it")
        XCTAssertTrue(messages.isEmpty,
                      "nothing was bound, so there is nothing to report — got \(messages)")
    }

    /// The ledger is JXCode's own bookkeeping rather than an agent's config, but
    /// it follows the rule the config writers follow: it is not created in order
    /// to record that it is empty.
    func testBindingAnEmptyCollectionRecordsNothing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sharedMCPManifest.path),
                       "the fixture should not start with a ledger")

        _ = try ConnectorBinder.apply(connectors: [], agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sharedMCPManifest.path),
                       "an empty collection has nothing to record, so nothing should be written")
    }

    /// Once the ledger exists it is emptied, not removed — it is what scopes the
    /// next revert, and a `.refused` agent may still be holding a live entry.
    func testAnExistingLedgerIsEmptiedRatherThanRemoved() throws {
        _ = try ConnectorBinder.apply(connectors: [connector()], agents: AgentRegistry.builtIns, paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sharedMCPManifest.path),
                      "binding a connector should leave a ledger behind")
        XCTAssertEqual(ConnectorBinder.readManifest(paths: paths).managed, ["filesystem"])

        _ = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sharedMCPManifest.path),
                      "the ledger is emptied rather than removed")
        XCTAssertTrue(ConnectorBinder.readManifest(paths: paths).managed.isEmpty,
                      "and it must no longer claim to manage anything")
    }

    /// A file that held nothing but our entries is removed, not blanked.
    ///
    /// Leaving a one-byte `AGENTS.md` behind is a change the user did not ask
    /// for, and it makes "never configured" and "configured, then unbound" look
    /// identical on disk.
    func testRevertRemovesTheFilesItCreated() throws {
        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)
        _ = try ConnectorBinder.apply(connectors: [connector()], agents: AgentRegistry.builtIns, paths: paths)

        for file in writtenConfigFiles + writtenInstructionFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "\(file.lastPathComponent) should exist after binding")
        }

        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)
        _ = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        for file in writtenConfigFiles + writtenInstructionFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "\(file.lastPathComponent) held nothing but our entries, so it should be removed")
        }
    }

    /// The backup has to hold the **user's** file.
    ///
    /// Taking one on the way *out* records our own block instead, and because
    /// `backUp` skips when a backup already exists, that wrong copy is the one
    /// that survives — which quietly turns the safety net into a decoy.
    func testTheBackupHoldsTheUsersOriginalNotOurBlock() throws {
        let file = paths.claudeMCPFile
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{"numStartups":42,"mcpServers":{"theirs":{"command":"their-server"}}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        _ = try ConnectorBinder.apply(connectors: [connector()], agents: AgentRegistry.builtIns, paths: paths)
        _ = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        let backup = try String(
            contentsOf: file.appendingPathExtension("jxcode-backup"), encoding: .utf8
        )
        XCTAssertFalse(backup.contains("filesystem"), "the backup must not contain our entry")
        XCTAssertTrue(backup.contains("their-server"), "the backup must be the user's file")
    }

    /// The whole point of the manifest: unbinding removes what we wrote and
    /// nothing else.
    func testUserContentSurvivesABindAndRevert() throws {
        let file = paths.claudeMCPFile
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{"numStartups":42,"mcpServers":{"theirs":{"command":"their-server"}}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        _ = try ConnectorBinder.apply(connectors: [connector()], agents: AgentRegistry.builtIns, paths: paths)
        var text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("their-server"), "their server must survive binding")
        XCTAssertTrue(text.contains("filesystem"), "ours should be added")

        _ = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("their-server"), "their server must survive unbinding")
        XCTAssertTrue(text.contains("42"), "their other keys must survive too")
        XCTAssertFalse(text.contains("filesystem"), "ours must be gone")
    }

    /// A `[table]` header ends TOML's top-level key section. Putting our tables
    /// first would make any of the user's own top-level assignments invalid —
    /// which is a syntax error in their config, caused by us.
    func testTheTOMLBlockIsAppendedAfterTheUsersOwnKeys() throws {
        let file = paths.codexMCPFile
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "# my notes\napproval_policy = \"never\"\n".write(to: file, atomically: true, encoding: .utf8)

        _ = try ConnectorBinder.apply(connectors: [connector()], agents: AgentRegistry.builtIns, paths: paths)

        let text = try String(contentsOf: file, encoding: .utf8)
        let userKey = try XCTUnwrap(text.range(of: "approval_policy"))
        let ourTable = try XCTUnwrap(text.range(of: "[mcp_servers."))
        XCTAssertLessThan(userKey.lowerBound, ourTable.lowerBound,
                          "our tables must follow the user's top-level keys, not precede them")
    }

    /// Text the user wrote around the block is not ours to touch, on either
    /// path — `bind` and `revert` make the same decision independently.
    func testRevertPreservesHandWrittenTextAroundTheBlock() throws {
        let file = try XCTUnwrap(SkillBinder.instructionFile(
            for: try agent("codex"), paths: paths
        ))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = "# Their own notes\n\nKeep me.\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        _ = try SkillBinder.apply(skills: [skill()], agents: AgentRegistry.builtIns, paths: paths)
        _ = try SkillBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), original,
            "unbinding must return their file as it found it, not reformatted"
        )
    }

    /// The same rule on the TOML path, where the block is *appended* rather than
    /// prepended — so the blank line to take with it is the one before, not the
    /// one after. Getting that backwards eats a line of the user's text.
    ///
    /// Bound **twice** on purpose. A single bind-and-revert passes even with the
    /// bug, because the first write is clean; it is the *second* write that
    /// re-derives the body from a file already containing our block, and that is
    /// where the user's blank lines were being collapsed. The realistic case is
    /// a user who re-binds, so the test has to re-bind.
    func testRevertReturnsTheUsersTOMLByteForByte() throws {
        let file = paths.codexMCPFile
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = "key1 = \"a\"\n\n\n[table]\nkey2 = \"b\"\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        for _ in 0..<2 {
            _ = try ConnectorBinder.apply(
                connectors: [connector()], agents: AgentRegistry.builtIns, paths: paths
            )
        }
        _ = try ConnectorBinder.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), original,
            "the user's blank lines and trailing newline must survive unbinding"
        )
    }

    // MARK: - Switching things on and off

    /// A connector with no command. This is the shape a hand-edited
    /// `connector.json` takes — and the store's JSON is documented as readable
    /// and hand-editable, so it is a shape the store is expected to hold.
    private func brokenConnector(id: String = "broken") -> Connector {
        Connector(id: id, name: "broken", transport: .stdio, command: "")
    }

    /// The regression. `enabled` is the user's field, so it has to be writable
    /// even when the connector itself is unusable.
    ///
    /// This was reachable and unrecoverable. The pane implemented its toggle by
    /// re-registering the connector, and registration validates — so an
    /// incomplete connector could never be switched *off*, which is the one
    /// action that would stop it being bound. `ConnectorBinder` already refuses
    /// to bind it, and that part is right; the dead end was that the row showed
    /// the refusal *and* a switch, and the switch did nothing.
    func testDisablingAConnectorThatFailsValidationStillWrites() throws {
        let broken = brokenConnector()
        XCTAssertNotNil(
            broken.validationError,
            "the fixture must actually be invalid, or this test proves nothing"
        )

        let store = SharedStore(paths: paths)
        try store.writeConnector(broken)
        try store.setConnectorEnabled(id: broken.id, enabled: false)

        XCTAssertEqual(
            SharedStore(paths: paths).connectors.first { $0.id == broken.id }?.enabled,
            false,
            "an unusable connector must still be switchable off"
        )
    }

    /// The other half of the same story: the binder declines to bind it. Refusing
    /// it at bind time and refusing to record the user's choice are different
    /// things, and the fix is to keep them separate — this test pins the first so
    /// the second cannot be "solved" by binding it anyway.
    func testAnInvalidConnectorIsRefusedAtBindTime() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(brokenConnector())

        let reports = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let refusal = reports.first { $0.action == .refused }
        XCTAssertEqual(refusal?.agentName, "broken",
                       "an incomplete connector should be reported, not silently bound")
    }

    /// A toggle is a toggle: nothing else on the record moves.
    func testTogglingAConnectorChangesOnlyTheEnabledFlag() throws {
        let store = SharedStore(paths: paths)
        let original = connector()
        try store.writeConnector(original)

        try store.setConnectorEnabled(id: original.id, enabled: false)

        let reloaded = try XCTUnwrap(SharedStore(paths: paths).connectors.first)
        XCTAssertEqual(reloaded.enabled, false)
        XCTAssertEqual(reloaded.id, original.id)
        XCTAssertEqual(reloaded.name, original.name)
        XCTAssertEqual(reloaded.command, original.command)
        XCTAssertEqual(reloaded.arguments, original.arguments)
        XCTAssertEqual(reloaded.transport, original.transport)
    }

    /// Skills already had a dedicated setter, which is why they behaved. Pinned
    /// so the three sections cannot drift apart again — the drift is what
    /// produced the connector bug in the first place.
    func testTogglingASkillWrites() throws {
        let store = SharedStore(paths: paths)
        try store.writeSkill(skill())

        try store.setSkillEnabled(id: "release", enabled: false)

        XCTAssertEqual(SharedStore(paths: paths).skills.first?.enabled, false)
    }

    /// Automations had the same re-add routing as connectors, minus the
    /// validation guard — so no dead end, but the same wrong "Registered …"
    /// message on every toggle.
    func testTogglingAnAutomationWrites() throws {
        let store = SharedStore(paths: paths)
        try store.writeAutomation(Automation(
            id: "nightly",
            name: "Nightly",
            agentID: "claude",
            prompt: "run the suite",
            schedule: AutomationSchedule(cadence: .daily, hour: 9, minute: 0)
        ))

        try store.setAutomationEnabled(id: "nightly", enabled: false)

        XCTAssertEqual(SharedStore(paths: paths).automations.first?.enabled, false)
    }

    /// An id that is not there is a no-op — not a crash, and not a new file.
    func testTogglingAnUnknownIdWritesNothing() throws {
        let store = SharedStore(paths: paths)

        try store.setConnectorEnabled(id: "nope", enabled: false)
        try store.setAutomationEnabled(id: "nope", enabled: false)

        let reloaded = SharedStore(paths: paths)
        XCTAssertTrue(reloaded.connectors.isEmpty)
        XCTAssertTrue(reloaded.automations.isEmpty)
    }
}
