import XCTest
@testable import JXCodeCore

/// The line-ending half of the "byte for byte" promise.
///
/// `CLAUDE.md`, `AGENTS.md` and `config.toml` are the user's files, and a bind
/// followed by a revert is supposed to return them unchanged. On a CRLF file it
/// did not: every writer split on `"\n"` and rejoined with `"\n"`, so the whole
/// file was converted on the way through. A Markdown diff will not show that,
/// which is why these compare bytes rather than looking for substrings.
final class ManagedBlockTests: XCTestCase {

    private let markers = ManagedBlock.Markers.markdownSkills
    private let block = "<!-- >>> jxcode skills >>> -->\n<!-- <<< jxcode skills <<< -->"

    // MARK: - TextLines

    func testSplitAndJoinAreInverses() {
        let cases = [
            "a\nb\nc",
            "a\r\nb\r\nc\r\n",
            "a\r\nb\nc\r\n",
            "a",
            "a\rb",
            "",
        ]
        for text in cases {
            XCTAssertEqual(
                TextLines.join(TextLines.split(text)), text,
                "the round trip changed \(text.debugDescription)"
            )
        }
        // The round trip alone cannot see a splitter that never splits: joining
        // one unsplit line back together is also the original text.
        XCTAssertEqual(TextLines.split("a\r\nb\r\n").count, 2)
        XCTAssertEqual(TextLines.split("a\nb\n").count, 2)
        XCTAssertEqual(TextLines.split("a\rb").count, 1, "a lone CR is content, not a terminator")
    }

    func testTerminatorFollowsTheMajority() {
        XCTAssertEqual(TextLines.terminator(of: "a\r\nb\r\n"), "\r\n")
        XCTAssertEqual(TextLines.terminator(of: "a\nb\n"), "\n")
        XCTAssertEqual(TextLines.terminator(of: "a\nb\nc\r\n"), "\n")
        XCTAssertEqual(TextLines.terminator(of: "a"), "\n", "a file with no line ending gets LF")
    }

    // MARK: - The contract

    func testACRLFFileSurvivesAnInsertAndItsRemoval() {
        let original = "# My agents\r\n\r\nSome notes\r\n\r\nMore notes\r\n"
        let written = ManagedBlock.inserting(block, into: original, markers: markers)
        XCTAssertTrue(
            written.contains("\r\n\r\n"),
            "the file was separated with LF: \(written.debugDescription)"
        )
        XCTAssertEqual(
            ManagedBlock.removingPreservingShape(from: written, markers: markers), original
        )
    }

    func testACRLFFileSurvivesAnAppendAndItsRemoval() {
        let original = "# heading\r\n\r\nbody\r\n"
        let written = ManagedBlock.appending(block, to: original, markers: markers)
        // The round trip alone would pass with LF separators: the block would
        // be taken back out just as cleanly. What has to be CRLF is what we
        // added.
        XCTAssertTrue(written.contains("\r\n\r\n"), "the file was separated with LF")
        XCTAssertEqual(
            ManagedBlock.removingPreservingShape(from: written, markers: markers), original
        )
    }

    /// A file that mixes the two cannot be served by normalising to either one.
    func testAMixedFileComesBackMixed() {
        let original = "# heading\r\n\r\nbody line\nsecond\r\n"
        let written = ManagedBlock.inserting(block, into: original, markers: markers)
        XCTAssertEqual(
            ManagedBlock.removingPreservingShape(from: written, markers: markers), original
        )
    }

    func testAnLFFileIsUntouched() {
        let original = "# heading\n\nbody\n"
        let written = ManagedBlock.appending(block, to: original, markers: markers)
        XCTAssertFalse(written.contains("\r\n"))
        XCTAssertEqual(
            ManagedBlock.removingPreservingShape(from: written, markers: markers), original
        )
    }
}
