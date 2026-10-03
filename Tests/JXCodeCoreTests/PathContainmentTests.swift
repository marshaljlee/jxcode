import XCTest
@testable import JXCodeCore

/// Containment is the question that decides whether something gets deleted, so
/// the wrong answer in either direction is a bug: yes to a sibling deletes the
/// user's directory, no to a child leaves our own stale link behind.
///
/// The cases are pure, which is the point — the two callers are filesystem
/// code, and a filesystem fixture can tell you a link was removed without
/// telling you *why*.
final class PathContainmentTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// The bug: `skills-archive` starts with `skills`.
    func testASiblingIsNotContained() {
        XCTAssertFalse(url("/x/skills-archive").isContained(in: url("/x/skills")))
        XCTAssertFalse(url("/x/skills-archive/deep/inside").isContained(in: url("/x/skills")))
    }

    func testAChildIsContained() {
        XCTAssertTrue(url("/x/skills/one").isContained(in: url("/x/skills")))
        XCTAssertTrue(url("/x/skills/one/two").isContained(in: url("/x/skills")))
    }

    /// The directory is not inside itself.
    func testADirectoryIsNotInsideItself() {
        XCTAssertFalse(url("/x/skills").isContained(in: url("/x/skills")))
        XCTAssertFalse(url("/x/skills/").isContained(in: url("/x/skills")))
    }

    /// A trailing slash on the container must not produce a double one, which
    /// would make every child answer no.
    func testATrailingSlashOnTheContainerMakesNoDifference() {
        XCTAssertTrue(url("/x/skills/one").isContained(in: url("/x/skills/")))
        XCTAssertFalse(url("/x/skills-archive").isContained(in: url("/x/skills/")))
    }

    /// `..` resolved before the comparison rather than after it — otherwise
    /// `skills/../skills-archive` reads as inside `skills`.
    func testDotdotIsResolvedBeforeTheComparison() {
        XCTAssertFalse(url("/x/skills/../skills-archive").isContained(in: url("/x/skills")))
        XCTAssertTrue(url("/x/skills/one/../two").isContained(in: url("/x/skills")))
    }
}
