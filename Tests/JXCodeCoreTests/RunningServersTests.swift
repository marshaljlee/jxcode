import XCTest
@testable import JXCodeCore

/// The parsing half of the conflicting-server check.
///
/// `list()` spawns `pgrep`, so it cannot be asserted on without depending on
/// what else happens to be running. `parse` is where the shape is decided, and
/// it is pure, so that is where the tests go.
final class RunningServersTests: XCTestCase {

    func testParseTakesThePidThenTheWholeCommand() {
        let entries = RunningServers.parse("1234 /opt/homebrew/bin/llama-server -m a.gguf\n")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].pid, 1234)
        XCTAssertEqual(entries[0].command, "/opt/homebrew/bin/llama-server -m a.gguf")
    }

    /// `-f` prints the full path, and a path can begin with digits. Splitting
    /// on the first space only is what stops `2024` being read as the pid here.
    func testParseIsNotConfusedByADigitInThePath() {
        let entries = RunningServers.parse("5678 /opt/2024/build/llama-server\n")
        XCTAssertEqual(entries.map(\.pid), [5678])
        XCTAssertEqual(entries[0].command, "/opt/2024/build/llama-server")
    }

    /// Several servers, one per line, is the case the warning is for.
    func testParseReportsEveryMatch() {
        let entries = RunningServers.parse("11 /usr/bin/llama-server\n22 /opt/homebrew/bin/llama-server\n")
        XCTAssertEqual(entries.map(\.pid), [11, 22])
    }

    /// The pid is the whole first field, not a digit-run found anywhere in the
    /// line. A field such as `11x` starts with a pid and is not one.
    func testParseRejectsAFieldThatOnlyStartsWithDigits() {
        XCTAssertTrue(RunningServers.parse("11x /usr/bin/llama-server\n").isEmpty)
    }

    func testParseSkipsLinesWithoutAPid() {
        let entries = RunningServers.parse("not-a-pid llama-server\n99 /usr/bin/llama-server\n")
        XCTAssertEqual(entries.map(\.pid), [99])
    }

    func testParseOfEmptyOutputIsEmpty() {
        XCTAssertTrue(RunningServers.parse("").isEmpty)
        XCTAssertTrue(RunningServers.parse("\n\n").isEmpty)
    }

    /// The listing used to hold a thread for as long as `pgrep` took. This only
    /// asserts that it finishes at all — a `waitUntilExit()` left in place
    /// would still pass — so the real guard is that no synchronous spelling of
    /// this call survives to be called from a view.
    func testListCompletes() async {
        let started = Date()
        _ = await RunningServers.list()
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }
}
