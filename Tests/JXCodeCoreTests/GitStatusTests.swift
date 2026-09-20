import XCTest
@testable import JXCodeCore

/// These tests build real repositories rather than mocking git: the value of
/// `GitStatus` is entirely in whether its parser matches what git actually
/// prints, and a fixture would just encode the same assumption twice.
final class GitStatusTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitstatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private struct GitRun {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Absolute locations, mirroring the order `GitStatus` itself searches.
    private static let gitCandidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ]

    private func requireGit() throws {
        guard Self.gitCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("git is not installed at any known location")
        }
    }

    private var gitPath: String {
        Self.gitCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }

    /// Runs git with the identity pinned on the command line, so the tests do
    /// not depend on -- or write to -- the developer's global git config.
    @discardableResult
    private func runGit(
        _ arguments: [String],
        in directory: URL,
        allowFailure: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> GitRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = [
            "-c", "user.email=test@example.com",
            "-c", "user.name=Test",
            "-c", "commit.gpgsign=false",
        ] + arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Test code can afford waitUntilExit; the API under test cannot, which
        // is exactly what `testSlowGitIsTerminatedByTimeout` pins down.
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = GitRun(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
        if !allowFailure && result.exitCode != 0 {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(result.stderr)", file: file, line: line)
        }
        return result
    }

    private func initRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let result = try runGit(["init", "-q", "-b", "main"], in: url, allowFailure: true)
        if result.exitCode != 0 {
            // Older git has no `-b`.
            try runGit(["init", "-q"], in: url)
            try runGit(["checkout", "-q", "-b", "main"], in: url, allowFailure: true)
        }
    }

    private func write(_ relativePath: String, _ contents: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String, in directory: URL) throws {
        try runGit(["add", "-A"], in: directory)
        try runGit(["commit", "-q", "-m", message], in: directory)
    }

    // MARK: - Clean repository

    func testCleanRepositoryReportsBranchAndHead() throws {
        try requireGit()
        let repo = root.appendingPathComponent("clean")
        try initRepo(at: repo)
        try write("a.txt", "hello\n", in: repo)
        try commit("initial commit", in: repo)

        let status = GitStatus.read(at: repo.path)

        XCTAssertTrue(status.isRepository)
        XCTAssertEqual(status.branch, "main")
        XCTAssertFalse(status.isDetached)
        XCTAssertEqual(status.changedFiles, 0)
        XCTAssertEqual(status.untrackedFiles, 0)
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.lastCommitSubject, "initial commit")
        XCTAssertNotNil(status.headShortSHA)
        XCTAssertNil(status.error)
        XCTAssertFalse(status.isDirty)
        XCTAssertEqual(status.summary, "main \u{00B7} clean")
    }

    // MARK: - Dirty counts

    func testCountsStagedUnstagedAndUntrackedSeparately() throws {
        try requireGit()
        let repo = root.appendingPathComponent("dirty")
        try initRepo(at: repo)
        try write("a.txt", "one\n", in: repo)
        try commit("initial commit", in: repo)

        // One unstaged modification, one staged addition, one untracked file.
        try write("a.txt", "one\ntwo\n", in: repo)
        try write("staged.txt", "staged\n", in: repo)
        try runGit(["add", "staged.txt"], in: repo)
        try write("untracked.txt", "loose\n", in: repo)

        let status = GitStatus.read(at: repo.path)

        XCTAssertTrue(status.isRepository)
        XCTAssertEqual(status.changedFiles, 2, "a.txt plus staged.txt")
        XCTAssertEqual(status.untrackedFiles, 1)
        XCTAssertTrue(status.isDirty)
        XCTAssertNil(status.error)
        XCTAssertTrue(status.summary.contains("2 changed"), status.summary)
        XCTAssertTrue(status.summary.contains("1 untracked"), status.summary)
    }

    func testStagedAndUnstagedEditsToOneFileCountOnce() throws {
        try requireGit()
        let repo = root.appendingPathComponent("both")
        try initRepo(at: repo)
        try write("a.txt", "one\n", in: repo)
        try commit("initial commit", in: repo)

        // Porcelain v2 emits a single entry per path even when the index and
        // the working tree have both moved, so this must not double-count.
        try write("a.txt", "two\n", in: repo)
        try runGit(["add", "a.txt"], in: repo)
        try write("a.txt", "three\n", in: repo)

        let status = GitStatus.read(at: repo.path)

        XCTAssertEqual(status.changedFiles, 1)
        XCTAssertEqual(status.untrackedFiles, 0)
    }

    // MARK: - Detached HEAD

    func testDetachedHeadIsNotAnError() throws {
        try requireGit()
        let repo = root.appendingPathComponent("detached")
        try initRepo(at: repo)
        try write("a.txt", "hello\n", in: repo)
        try commit("initial commit", in: repo)
        try runGit(["checkout", "-q", "--detach", "HEAD"], in: repo)

        let status = GitStatus.read(at: repo.path)

        XCTAssertTrue(status.isRepository)
        XCTAssertTrue(status.isDetached)
        XCTAssertNil(status.branch)
        XCTAssertNil(status.error, "a detached HEAD is a normal state, not a failure")
        XCTAssertNotNil(status.headShortSHA)
        XCTAssertEqual(status.lastCommitSubject, "initial commit")
        XCTAssertTrue(status.summary.contains("detached"), status.summary)
    }

    // MARK: - Unborn branch

    func testRepositoryWithNoCommitsIsNotAnError() throws {
        try requireGit()
        let repo = root.appendingPathComponent("unborn")
        try initRepo(at: repo)

        let status = GitStatus.read(at: repo.path)

        XCTAssertTrue(status.isRepository)
        XCTAssertEqual(status.branch, "main")
        XCTAssertFalse(status.isDetached)
        XCTAssertNil(status.error, "an unborn branch is a normal state, not a failure")
        XCTAssertNil(status.headShortSHA, "(initial) must not be reported as a sha")
        XCTAssertNil(status.lastCommitSubject)
        XCTAssertEqual(status.changedFiles, 0)
    }

    func testUnbornBranchWithStagedFileStillReportsTheRepo() throws {
        try requireGit()
        let repo = root.appendingPathComponent("unborn-staged")
        try initRepo(at: repo)
        try write("a.txt", "hello\n", in: repo)
        try runGit(["add", "a.txt"], in: repo)

        let status = GitStatus.read(at: repo.path)

        XCTAssertTrue(status.isRepository)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.changedFiles, 1)
        XCTAssertNil(status.headShortSHA)
    }

    // MARK: - Failure modes

    func testDirectoryThatIsNotARepository() throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let status = GitStatus.read(at: plain.path)

        XCTAssertFalse(status.isRepository)
        XCTAssertNil(status.error, "not being a repository is an answer, not an error")
        XCTAssertEqual(status, GitStatus.notARepository)
        XCTAssertFalse(status.isDirty)
        XCTAssertNil(status.branch)
        XCTAssertEqual(status.summary, "not a repository")
    }

    func testNonexistentPath() throws {
        let missing = root.appendingPathComponent("does-not-exist")

        let status = GitStatus.read(at: missing.path)

        XCTAssertFalse(status.isRepository)
        XCTAssertNotNil(status.error)
        XCTAssertFalse(status.isDirty)
    }

    func testGitUnavailable() throws {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let bogus = root.appendingPathComponent("no-such-git")

        let status = GitStatus.read(at: repo.path, gitBinary: bogus)

        XCTAssertFalse(status.isRepository)
        XCTAssertNotNil(status.error)
        XCTAssertFalse(status.isDirty)
        XCTAssertEqual(status.summary, "git error")
    }

    func testNonExecutableGitBinaryIsRejected() throws {
        let bogus = root.appendingPathComponent("git-not-executable")
        try "not a program".write(to: bogus, atomically: true, encoding: .utf8)

        let status = GitStatus.read(at: root.path, gitBinary: bogus)

        XCTAssertFalse(status.isRepository)
        XCTAssertNotNil(status.error)
    }

    /// The app runs agents with a rebuilt PATH that omits Homebrew, so a
    /// workspace opened through the sandbox must still resolve git.
    func testFindsGitWithSandboxPathThatExcludesHomebrew() throws {
        try requireGit()
        let repo = root.appendingPathComponent("sandboxed")
        try initRepo(at: repo)
        try write("a.txt", "hello\n", in: repo)
        try commit("initial commit", in: repo)

        let sandboxEnvironment = [
            "PATH": "/usr/bin:/bin",
            "HOME": root.appendingPathComponent("home").path,
        ]
        let status = GitStatus.read(at: repo.path, environment: sandboxEnvironment)

        XCTAssertTrue(status.isRepository)
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.error)
    }

    func testNilEnvironmentInheritsTheProcessEnvironment() throws {
        try requireGit()
        let repo = root.appendingPathComponent("inherited")
        try initRepo(at: repo)
        try write("a.txt", "hello\n", in: repo)
        try commit("initial commit", in: repo)

        let status = GitStatus.read(at: repo.path, environment: nil)

        XCTAssertTrue(status.isRepository)
        XCTAssertNil(status.error)
    }

    // MARK: - Timeout

    func testSlowGitIsTerminatedByTimeout() throws {
        // `exec` matters: without it the shell forks `sleep` and survives
        // SIGTERM, leaving a child holding the pipe open.
        let script = root.appendingPathComponent("slow-git")
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let started = Date()
        let status = GitStatus.read(at: root.path, gitBinary: script)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(status.isRepository)
        XCTAssertTrue(
            status.error?.contains("timed out") ?? false,
            "expected a timeout error, got \(status.error ?? "nil")"
        )
        XCTAssertLessThan(elapsed, GitStatus.timeout + 5, "read must not outlive its deadline")
    }

    // MARK: - Ahead / behind

    func testAheadAndBehindAgainstBareRemote() throws {
        try requireGit()

        let work = root.appendingPathComponent("work")
        try initRepo(at: work)
        try write("f.txt", "a\n", in: work)
        try commit("base", in: work)

        let bare = root.appendingPathComponent("origin.git")
        let bareInit = try runGit(["init", "-q", "--bare", "-b", "main", bare.path], in: root, allowFailure: true)
        if bareInit.exitCode != 0 {
            try runGit(["init", "-q", "--bare", bare.path], in: root)
            try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: bare)
        }

        try runGit(["remote", "add", "origin", bare.path], in: work)
        try runGit(["push", "-q", "-u", "origin", "main"], in: work)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: bare, allowFailure: true)

        let clean = GitStatus.read(at: work.path)
        XCTAssertEqual(clean.ahead, 0, clean.error ?? "")
        XCTAssertEqual(clean.behind, 0, clean.error ?? "")

        try write("f.txt", "a\nb\n", in: work)
        try commit("local 1", in: work)
        try write("f.txt", "a\nb\nc\n", in: work)
        try commit("local 2", in: work)

        let aheadOnly = GitStatus.read(at: work.path)
        XCTAssertEqual(aheadOnly.ahead, 2, aheadOnly.error ?? "")
        XCTAssertEqual(aheadOnly.behind, 0)
        XCTAssertTrue(aheadOnly.summary.contains("2 ahead"), aheadOnly.summary)

        // A second clone supplies the commit that puts `work` behind.
        let other = root.appendingPathComponent("other")
        try runGit(["clone", "-q", bare.path, other.path], in: root)
        try write("g.txt", "remote\n", in: other)
        try commit("remote 1", in: other)
        try runGit(["push", "-q", "origin", "main"], in: other)
        try runGit(["fetch", "-q", "origin"], in: work)

        let diverged = GitStatus.read(at: work.path)
        XCTAssertEqual(diverged.ahead, 2, diverged.error ?? "")
        XCTAssertEqual(diverged.behind, 1)
        XCTAssertTrue(diverged.summary.contains("2 ahead"), diverged.summary)
        XCTAssertTrue(diverged.summary.contains("1 behind"), diverged.summary)
    }

    // MARK: - Value semantics

    func testStatusIsCodableAndRoundTrips() throws {
        let original = GitStatus(
            isRepository: true,
            branch: "feature/x",
            isDetached: false,
            changedFiles: 3,
            untrackedFiles: 2,
            ahead: 1,
            behind: 4,
            headShortSHA: "abc1234",
            lastCommitSubject: "add thing",
            error: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GitStatus.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isDirty)
        XCTAssertEqual(decoded.summary, "feature/x \u{00B7} 3 changed \u{00B7} 2 untracked \u{00B7} 1 ahead \u{00B7} 4 behind")
    }

    func testNotARepositoryIsNotDirty() {
        XCTAssertFalse(GitStatus.notARepository.isDirty)
        XCTAssertFalse(GitStatus.notARepository.isRepository)
        XCTAssertNil(GitStatus.notARepository.error)
    }
}
