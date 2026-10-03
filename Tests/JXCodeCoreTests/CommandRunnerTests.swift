import XCTest
@testable import JXCodeCore

/// One-shot commands inside the sandbox: probes, installs, version checks.
///
/// The output is the point of running one, so what matters here is that every
/// byte arrives, in order, on the right stream. A race in the reading loses
/// neither much nor often — it drops or reorders one chunk out of several — so
/// the integrity test writes well past one pipe buffer and checks the whole
/// thing rather than looking for a substring.
final class CommandRunnerTests: XCTestCase {

    private let environment = ProcessInfo.processInfo.environment
    private var directory: String { FileManager.default.temporaryDirectory.path }

    private func sh(_ script: String, timeout: TimeInterval = 30) throws -> CommandResult {
        try CommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            workingDirectory: directory,
            timeout: timeout
        )
    }

    // MARK: - The streams

    func testStdoutAndStderrAreCapturedSeparately() throws {
        let result = try sh("echo out; echo err 1>&2")

        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTheExitCodeIsCarried() throws {
        XCTAssertEqual(try sh("exit 3").exitCode, 3)
    }

    // MARK: - Integrity

    /// Far more than one pipe buffer, so the reader runs several times and a
    /// chunk that is dropped or appended late changes the result.
    func testALargeStdoutArrivesWholeAndInOrder() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-runner-\(UUID().uuidString).txt")
        let expected = (1...60_000).map { String(format: "%08d\n", $0) }.joined()
        try expected.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertTrue(expected.utf8.count > 400_000, "the fixture is not large enough to matter")

        for _ in 0..<3 {
            let result = try CommandRunner.run(
                executable: "/bin/cat",
                arguments: [file.path],
                environment: environment,
                workingDirectory: directory
            )
            XCTAssertEqual(result.stdout.utf8.count, expected.utf8.count, "output was truncated")
            XCTAssertEqual(
                result.stdout.prefix(16), expected.prefix(16), "the first chunk is out of order"
            )
            XCTAssertEqual(result.stdout, expected)
        }
    }

    /// Both streams at once, both large: the two readers are independent, and
    /// interleaving them is what a shared buffer would do.
    func testBothStreamsArriveWholeWhenWrittenTogether() throws {
        let result = try sh("for i in $(seq 1 4000); do echo out-$i; echo err-$i 1>&2; done")

        XCTAssertEqual(result.stdout.split(separator: "\n").count, 4000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 4000)
        XCTAssertTrue(result.stdout.hasPrefix("out-1\n"), "stdout is out of order")
        XCTAssertTrue(result.stderr.hasPrefix("err-1\n"), "stderr is out of order")
        XCTAssertTrue(result.stdout.hasSuffix("out-4000\n"), "stdout is truncated")
        XCTAssertTrue(result.stderr.hasSuffix("err-4000\n"), "stderr is truncated")
    }

    // MARK: - The edges

    func testACommandThatRunsPastItsTimeoutIsReported() throws {
        let result = try sh("sleep 30", timeout: 0.5)

        XCTAssertTrue(result.timedOut, "a command killed for running long was not marked")
        XCTAssertFalse(result.succeeded)
    }

    func testACommandThatIsNotExecutableIsRejectedBeforeRunning() {
        XCTAssertThrowsError(
            try CommandRunner.run(
                executable: "/bin/cat/definitely-not-a-file",
                environment: environment,
                workingDirectory: directory
            )
        )
    }
}
