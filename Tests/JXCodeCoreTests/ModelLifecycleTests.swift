import XCTest
@testable import JXCodeCore

/// The alias table, and the rule it exists to enforce.
///
/// An alias is the stable name an agent's config holds; a profile is the
/// volatile binding behind it. Most of what can go wrong here is a *name* going
/// wrong — two entries that differ only in case, a name that means one thing in
/// a shell and another in a JSON body — so most of these tests are about what a
/// name may be and which entry wins when two of them collide.
///
/// The counts are asserted rather than the presence of values, deliberately.
/// "`Coder` is in the list" is true whether or not `coder` is still beside it,
/// and the duplicate is the whole defect.
final class ModelLifecycleTests: XCTestCase {

    private var base: URL!
    private var paths: SandboxPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("jxcode-lifecycle-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        paths = SandboxPaths(root: base)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    /// A file that exists, because an alias may only be bound to one.
    @discardableResult
    private func makeModelFile(_ name: String = "model.gguf") throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data("not really a gguf".utf8).write(to: url)
        return url
    }

    private func makeStore() -> ModelLifecycleStore {
        ModelLifecycleStore(paths: paths)
    }

    // MARK: - Binding

    /// The check `ModelLifecycleError.missingModel` was written for and, until
    /// this track finished, was never thrown by: a case with a written-out
    /// message that no code path reached.
    func testAnAliasMayOnlyBeBoundToAFileThatExists() throws {
        let store = makeStore()
        let missing = base.appendingPathComponent("nowhere.gguf")

        XCTAssertThrowsError(try store.setAlias(ModelAlias(name: "ghost", modelPath: missing.path))) {
            guard case .missingModel(let url)? = $0 as? ModelLifecycleError else {
                return XCTFail("expected missingModel, got \($0)")
            }
            XCTAssertEqual(url.path, missing.path)
        }
        XCTAssertEqual(store.knownAliases.count, 0, "a refused bind left an entry behind")
    }

    /// `~` is expanded *before* the file is checked, so the failure names the
    /// path that was looked for rather than the path that was typed. The
    /// expansion goes through `getpwuid()` and not `$HOME` — the same caveat the
    /// README records for the whole app — which is why the assertion is only
    /// that the result is absolute and tilde-free.
    func testTildeIsExpandedBeforeTheFileIsChecked() {
        let store = makeStore()
        let typed = "~/Models/nope-\(UUID().uuidString).gguf"

        XCTAssertThrowsError(try store.setAlias(ModelAlias(name: "ghost", modelPath: typed))) {
            guard case .missingModel(let url)? = $0 as? ModelLifecycleError else {
                return XCTFail("expected missingModel, got \($0)")
            }
            XCTAssertFalse(url.path.contains("~"), "the path was not expanded: \(url.path)")
            XCTAssertTrue(url.path.hasPrefix("/"), "\(url.path) is not absolute")
        }
    }

    func testBindingStoresAStandardisedAbsolutePath() throws {
        let file = try makeModelFile()
        let store = makeStore()

        try store.setAlias(ModelAlias(name: "coder", modelPath: base.path + "/./model.gguf"))

        let stored = try XCTUnwrap(store.alias(named: "coder"))
        XCTAssertEqual(stored.modelPath, file.standardizedFileURL.path)
        XCTAssertFalse(stored.modelPath.contains("/./"), "the path was stored as typed")
    }

    /// The upsert is on the *folded* name, so two entries that differ only in
    /// case cannot both exist. If they could, "which model does `coder` get"
    /// would depend on scan order.
    func testUpsertFoldsCaseSoThereIsNeverMoreThanOneEntryPerName() throws {
        let file = try makeModelFile()
        let store = makeStore()

        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))
        try store.setAlias(ModelAlias(name: "Coder", modelPath: file.path))

        XCTAssertEqual(store.knownAliases.count, 1, "the two names both survived")
        XCTAssertEqual(store.knownAliases, ["Coder"], "the later bind did not replace the earlier")
    }

    func testAnAliasIsFoundCaseInsensitively() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))

        XCTAssertNotNil(store.alias(named: "CODER"))
        XCTAssertNotNil(store.alias(named: "Coder"))
    }

    /// `false` rather than a throw, which is why the error enum no longer has an
    /// `unknownAlias` case: an unbind that fails on its second run makes a
    /// cleanup script fail on its second run.
    func testRemovingAnAliasThatIsNotBoundIsFalseRatherThanAnError() throws {
        let store = makeStore()
        XCTAssertFalse(try store.removeAlias(named: "nobody"))
    }

    func testRemovingABoundAliasSaysItRemovedOne() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))

        XCTAssertTrue(try store.removeAlias(named: "coder"))
        XCTAssertEqual(store.knownAliases.count, 0)
    }

    // MARK: - What a name may be

    /// The allowlist is the point: `coder/2` and `coder:2` look fine in a shell
    /// and mean something else in a config file and a URL path.
    func testANameThatMeansSomethingElseInAShellIsRefused() {
        let store = makeStore()
        for bad in ["coder/2", "coder:2", "co der", "coder\n2", "", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(
                try store.setAlias(ModelAlias(name: bad, modelPath: base.path)),
                "'\(bad)' should not be usable as an alias"
            ) { error in
                guard case .invalidName? = error as? ModelLifecycleError else {
                    return XCTFail("expected invalidName for '\(bad)', got \(error)")
                }
            }
        }
    }

    func testAProfileNameIsValidatedTheSameWay() {
        let store = makeStore()
        XCTAssertThrowsError(try store.addProfile(named: "work/2")) {
            guard case .invalidName? = $0 as? ModelLifecycleError else {
                return XCTFail("expected invalidName, got \($0)")
            }
        }
    }

    // MARK: - Profiles

    func testADuplicateProfileIsRefusedCaseInsensitively() throws {
        let store = makeStore()
        try store.addProfile(named: "work")

        XCTAssertThrowsError(try store.addProfile(named: "Work")) {
            guard case .duplicateProfile? = $0 as? ModelLifecycleError else {
                return XCTFail("expected duplicateProfile, got \($0)")
            }
        }
        XCTAssertEqual(store.knownProfileNames.count, 2, "default + work, and no third")
    }

    /// Removing the only profile would leave the router with nowhere to resolve
    /// an alias, which is a state with no error message that explains it.
    func testTheLastProfileCannotBeRemoved() {
        let store = makeStore()
        XCTAssertEqual(store.knownProfileNames, [ModelLifecycleStore.defaultProfileName])

        XCTAssertThrowsError(try store.removeProfile(named: ModelLifecycleStore.defaultProfileName)) {
            guard case .lastProfile? = $0 as? ModelLifecycleError else {
                return XCTFail("expected lastProfile, got \($0)")
            }
        }
        XCTAssertEqual(store.knownProfileNames.count, 1)
    }

    func testSelectingAnUnknownProfileNamesTheOnesThatExist() throws {
        let store = makeStore()
        try store.addProfile(named: "work")

        XCTAssertThrowsError(try store.selectProfile(named: "nope")) {
            guard case .unknownProfile(let name, let known)? = $0 as? ModelLifecycleError else {
                return XCTFail("expected unknownProfile, got \($0)")
            }
            XCTAssertEqual(name, "nope")
            XCTAssertEqual(known.sorted(), ["default", "work"])
        }
    }

    func testRemovingTheActiveProfileMovesTheActiveNameToAnother() throws {
        let store = makeStore()
        try store.addProfile(named: "work")
        try store.selectProfile(named: "work")

        try store.removeProfile(named: "work")

        XCTAssertEqual(store.knownProfileNames, ["default"])
        XCTAssertEqual(store.activeProfile.name, "default")
    }

    /// A file naming a profile that is not in it falls back to the first one
    /// rather than to nothing: an alias table that resolves to nothing looks
    /// identical to a table with no aliases, and only one of those is a mistake.
    func testAnActiveProfileMissingFromTheFileIsRepairedOnLoad() throws {
        let store = makeStore()
        try store.addProfile(named: "work")

        // Hand-written rather than round-tripped through the private `Stored`
        // shape, so the test still exercises the repair if that shape changes.
        let json = """
        {
          "activeProfile": "deleted-elsewhere",
          "profiles": [
            { "name": "work", "aliases": [], "idleTimeout": 900 },
            { "name": "spare", "aliases": [], "idleTimeout": 900 }
          ]
        }
        """
        try Data(json.utf8).write(to: store.file)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.activeProfile.name, "work", "the repair did not happen")
        XCTAssertEqual(reloaded.knownProfileNames, ["work", "spare"])
    }

    func testAnIdleTimeoutMustNotBeNegative() {
        let store = makeStore()
        XCTAssertThrowsError(try store.setIdleTimeout(-1)) {
            guard case .invalidIdleTimeout? = $0 as? ModelLifecycleError else {
                return XCTFail("expected invalidIdleTimeout, got \($0)")
            }
        }
        XCTAssertThrowsError(
            try store.setAlias(ModelAlias(name: "coder", modelPath: base.path, idleTimeout: -5))
        )
    }

    /// Zero is legal and means "never unload", which is a different thing from
    /// a missing value — the missing one inherits the profile.
    func testZeroIsAnIdleTimeoutAndNotAnAbsence() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path, idleTimeout: 0))

        let alias = try XCTUnwrap(store.alias(named: "coder"))
        XCTAssertEqual(alias.idleTimeout, 0)
        XCTAssertNotNil(alias.idleTimeout, "0 was folded into nil")
    }

    /// When a profile somehow holds two entries that differ only in case, the
    /// first wins — deterministically, and matching what the file reads like.
    func testTheFirstOfTwoCaseCollidingEntriesWins() {
        let profile = ModelProfile(name: "p", aliases: [
            ModelAlias(name: "coder", modelPath: "/a.gguf"),
            ModelAlias(name: "Coder", modelPath: "/b.gguf"),
        ])
        XCTAssertEqual(profile.alias(named: "CODER")?.modelPath, "/a.gguf")
    }

    // MARK: - The effective idle timeout

    /// The rule the whole surface follows: show the value that will be used,
    /// with the reason it won. "No override" is not "no timeout".
    func testAnAliasTimeoutOverridesTheProfileAndSaysSo() {
        let profile = ModelProfile(name: "p", aliases: [], idleTimeout: 900)
        let own = ModelAlias(name: "coder", modelPath: "/a.gguf", idleTimeout: 60)
        let inherited = ModelAlias(name: "vision", modelPath: "/b.gguf")

        XCTAssertEqual(ModelLifecycleReport.effectiveIdle(own, in: profile), 60)
        XCTAssertEqual(ModelLifecycleReport.idleOrigin(own), "this alias")

        XCTAssertEqual(ModelLifecycleReport.effectiveIdle(inherited, in: profile), 900)
        XCTAssertEqual(ModelLifecycleReport.idleOrigin(inherited), "the profile")
    }

    /// `0` means "keep it loaded", and `0s` reads as "unload immediately" —
    /// which is the opposite. The flag's own vocabulary is the trap, so the one
    /// place it is rendered is pinned here.
    func testZeroIsSpelledOutRatherThanRenderedAsZeroSeconds() {
        let line = ModelLifecycleReport.idleLine(0, origin: "this alias")

        XCTAssertTrue(line.contains("kept loaded"), line)
        XCTAssertFalse(line.contains("0s"), "0 was rendered as a duration: \(line)")
    }

    // MARK: - The rendered report

    /// The defect the live run found: `idleLine` already prints the label, and
    /// the caller printed it again, so the terminal read
    /// `idle timeout  idle timeout  10m 0s`.
    func testTheProfileReportDoesNotPrintTheIdleLabelTwice() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))

        let rendered = ModelLifecycleReport.profiles(store)

        XCTAssertFalse(
            rendered.contains("idle timeout  idle timeout"),
            "the label was doubled:\n\(rendered)"
        )
        XCTAssertEqual(
            rendered.components(separatedBy: "idle timeout").count - 1, 2,
            "expected one label for the profile and one for the alias:\n\(rendered)"
        )
    }

    func testTheReportSaysWhereEachIdleTimeoutCameFrom() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setIdleTimeout(600)
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path, idleTimeout: 60))
        try store.setAlias(ModelAlias(name: "vision", modelPath: file.path))

        let rendered = ModelLifecycleReport.profiles(store)

        XCTAssertTrue(rendered.contains("(from this alias)"), rendered)
        XCTAssertTrue(rendered.contains("(from the profile)"), rendered)
        XCTAssertTrue(rendered.contains("1m 0s"), "the alias's own 60s is missing:\n\(rendered)")
        XCTAssertTrue(rendered.contains("10m 0s"), "the inherited 600s is missing:\n\(rendered)")
    }

    /// An alias whose model has been moved is still a valid row, and this is the
    /// only place that failure is visible before a request fails minutes later.
    func testAnAliasWhoseFileHasGoneIsMarkedMissingInTheReport() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))
        try fm.removeItem(at: file)

        let rendered = ModelLifecycleReport.profiles(store)

        XCTAssertTrue(rendered.contains("missing"), rendered)
        XCTAssertEqual(
            rendered.components(separatedBy: "missing").count - 1, 1,
            "exactly one alias has a missing file:\n\(rendered)"
        )
    }

    // MARK: - The four log streams

    func testTheModelStreamNeedsAnAliasAndTheOthersDoNot() {
        let logs = ModelLogs(paths: paths)

        XCTAssertNil(logs.fileURL(.model), "a per-model stream answered without a model")
        for stream in ModelLogStream.allCases where !stream.isPerModel {
            XCTAssertNotNil(logs.fileURL(stream), "\(stream.rawValue) should not need an alias")
        }
    }

    func testThePerModelLogIsNamedForTheAliasAndNotTheModel() {
        let logs = ModelLogs(paths: paths)
        let url = logs.fileURL(.model, alias: "Coder")

        XCTAssertEqual(url?.lastPathComponent, "coder.log")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "models")
    }

    /// Defence against a hand-edited file rather than against the writer: an
    /// alias is validated on the way in, but an older file may hold anything.
    func testASlugCannotEscapeTheLogDirectory() {
        XCTAssertEqual(ModelLogs.slug("../../etc/passwd"), "..-..-etc-passwd")
        XCTAssertEqual(ModelLogs.slug("a b"), "a-b")
        XCTAssertEqual(ModelLogs.slug(""), "unnamed")
    }

    func testPreparingAStreamCreatesAnEmptyFileSoAPaneShowsNoError() throws {
        let logs = ModelLogs(paths: paths)
        let url = try XCTUnwrap(logs.prepare(.model, alias: "coder"))

        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(logs.tail(.model, alias: "coder"), "")
    }

    // MARK: - The fan-out

    /// `logs/upstream.log` was created by `ModelLogs.prepare` and written to by
    /// nothing, so a pane showing it showed an empty file under a heading that
    /// promised every server's output.
    func testTheTeeWritesEveryByteToEveryFileItWasGiven() throws {
        let first = base.appendingPathComponent("one.log")
        let second = base.appendingPathComponent("two.log")
        let tee = LogTee(urls: [first, second])

        XCTAssertTrue(tee.isOpen)
        tee.write(Data("loading model\n".utf8))
        tee.write(Data("ready\n".utf8))
        tee.close()

        for url in [first, second] {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(text, "loading model\nready\n", "\(url.lastPathComponent) is wrong")
        }
    }

    func testTheTeeAppendsRatherThanTruncatingASecondRun() throws {
        let url = base.appendingPathComponent("one.log")
        try Data("first run\n".utf8).write(to: url)

        let tee = LogTee(urls: [url])
        tee.write(Data("second run\n".utf8))
        tee.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first run\nsecond run\n")
    }

    func testTeeingToNothingIsRefusedRatherThanSilentlyWritingNowhere() {
        // A directory cannot be opened for writing, so this is the "nowhere to
        // put the output" case: the caller has to refuse rather than start a
        // server whose log goes into the void.
        let tee = LogTee(urls: [base])
        XCTAssertFalse(tee.isOpen)
    }

    // MARK: - Servers this process did not start

    func testAPortIsReadFromEitherSpelling() {
        XCTAssertEqual(
            ModelLifecycleReport.parseServerCommandLine(
                "/opt/homebrew/bin/llama-server -m /m/a.gguf --port 8081 --host 127.0.0.1"
            ).port,
            8081
        )
        XCTAssertEqual(
            ModelLifecycleReport.parseServerCommandLine("llama-server --port=18434").port,
            18434
        )
        XCTAssertNil(ModelLifecycleReport.parseServerCommandLine("llama-server -m /m/a.gguf").port)
    }

    func testTheModelIsTakenFromTheFlagBeforeTheBareGguf() {
        let parsed = ModelLifecycleReport.parseServerCommandLine(
            "llama-server --mmproj /m/mmproj-a.gguf -m /m/a.gguf"
        )
        XCTAssertEqual(parsed.modelPath, "/m/a.gguf", "the projector was read as the model")
    }

    func testAModelIsStillFoundWithNoFlagInFrontOfIt() {
        let parsed = ModelLifecycleReport.parseServerCommandLine("llama-server /m/a.gguf --port 9000")
        XCTAssertEqual(parsed.modelPath, "/m/a.gguf")
    }

    func testARunningServerIsMatchedToTheAliasThatPointsAtItsModel() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))

        let matched = ModelLifecycleReport.runningElsewhere(
            [
                RunningServers.Entry(pid: 11, command: "llama-server -m \(file.path) --port 8080"),
                RunningServers.Entry(pid: 22, command: "llama-server -m /elsewhere/b.gguf --port 8081"),
            ],
            store: store
        )

        XCTAssertEqual(matched.count, 2)
        XCTAssertEqual(matched[0].alias, "coder")
        XCTAssertNil(matched[1].alias, "a server pointing at another file was claimed as ours")
    }

    func testTheForeignServerReportSaysSoWhenThereAreNone() {
        let rendered = ModelLifecycleReport.foreignServers([])
        XCTAssertTrue(rendered.contains("No llama-server"), rendered)
    }

    func testAForeignServerWithNoAliasIsNamedRatherThanLeftBlank() {
        let rendered = ModelLifecycleReport.foreignServers([
            ModelLifecycleReport.ForeignServer(
                pid: 7, port: 8080, modelPath: "/m/a.gguf", alias: nil,
                mode: .oneModel(path: "/m/a.gguf")
            )
        ])

        XCTAssertTrue(rendered.contains("not bound to an alias"), rendered)
        XCTAssertTrue(rendered.contains("http://127.0.0.1:8080"), rendered)
    }

    // MARK: - Persistence

    func testTheTableSurvivesAReload() throws {
        let file = try makeModelFile()
        let store = makeStore()
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path, idleTimeout: 45))
        try store.addProfile(named: "work")
        try store.selectProfile(named: "work")

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.activeProfile.name, "work")
        XCTAssertEqual(reloaded.knownProfileNames.sorted(), ["default", "work"])
        // The alias belongs to `default`, which is not the active profile now,
        // so it must not resolve — a profile that leaked into another would make
        // switching meaningless.
        XCTAssertNil(reloaded.alias(named: "coder"))
        XCTAssertEqual(reloaded.profile(named: "default")?.aliases.count, 1)
    }
}
