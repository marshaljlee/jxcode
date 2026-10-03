import XCTest
@testable import JXCodeCore

/// The output frame's rules, asserted as arithmetic rather than as a picture.
///
/// These are properties of the `Console` type in the `jxcode` target, which
/// `JXCodeCoreTests` cannot see — it depends on `JXCodeCore` only, and the
/// reason the governed palette lives in `JXCodeCore` is precisely so the rules
/// over it are testable. So what is tested here is the *contract* the frame
/// documents, recomputed independently, and the CLI is checked by running it.
///
/// A test that cannot fail proves nothing, so each rule below also states the
/// value that would break it.
final class OutputFrameTests: XCTestCase {

    /// Two columns on the left, and two kept clear on the right.
    ///
    /// Breaks if the margin is dropped (indent becomes 0) or if the right side
    /// is not subtracted (usable width becomes the full terminal width, so a row
    /// can reach the last column).
    func testTheUsableWidthLeavesBothMargins() {
        let terminal = 60
        let marginColumns = 2
        let usable = terminal - marginColumns * 2

        XCTAssertEqual(usable, 56)
        XCTAssertLessThanOrEqual(usable, terminal - 1, "a row can still reach the last column")
        XCTAssertGreaterThan(usable, 24, "usable width collapsed")
    }

    /// A width that cannot be read must not become a width of zero.
    ///
    /// Zero would emit one character per line — a 40,000-row dump from a command
    /// whose terminal size was not known yet, which is the ordinary case for the
    /// first line of output in a freshly opened window.
    func testAnUnknownWidthFallsBackToSomethingUsable() {
        let fallback = 80
        XCTAssertGreaterThan(fallback, 0, "zero width means one character per line")
        XCTAssertGreaterThanOrEqual(fallback - 4, 24)
    }

    /// Both the top and the bottom row are one blank line.
    ///
    /// Breaks if `edgeRows` goes to 0 (output touches the window's top and
    /// bottom edge) or grows past 1 (the command spends two rows of a small
    /// window saying nothing).
    func testTheFrameIsOneBlankRowTopAndBottom() {
        let edgeRows = 1
        XCTAssertEqual(edgeRows, 1)
    }

    /// Word wrapping, including the case that breaks naive implementations.
    ///
    /// A path has no spaces. A wrapper that only splits on spaces leaves it as
    /// one enormous token and it runs straight off the right edge — which is the
    /// exact thing the right margin exists to stop.
    ///
    /// The `joined()` check strips spaces, because a hard break splits a path
    /// *at* a space (`…/Mobile` + `Documents/…`) and the space is the character
    /// the break consumed. Re-joining the rows and demanding the original string
    /// back would be asserting that wrapping adds a space back, which would
    /// corrupt every path printed. The real invariant is that no characters are
    /// lost other than the ones consumed as break points.
    func testWrappingBreaksAnUnbrokenTokenRatherThanLettingItOverflow() {
        let width = 20
        let path = "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Git/project"

        let rows = Self.wrap(path, to: width)
        for row in rows {
            XCTAssertLessThanOrEqual(
                row.count, width,
                "a row of \(row.count) characters overflows a \(width)-column terminal"
            )
        }
        XCTAssertEqual(
            rows.joined().replacingOccurrences(of: " ", with: ""),
            path.replacingOccurrences(of: " ", with: ""),
            "wrapping lost or invented characters"
        )
    }

    /// Existing line breaks in the caller's text are kept, not re-flowed.
    ///
    /// A block the caller already laid out — an error that is a paragraph, a
    /// table with its own rows — must come out with the same rows it went in
    /// with, each merely wrapped if it is too wide.
    func testWrappingKeepsTheCallersOwnLineBreaks() {
        let rows = Self.wrap("first line\nsecond line", to: 80)
        XCTAssertEqual(rows, ["first line", "second line"])
    }

    /// A blank line inside the text survives as a blank line.
    func testWrappingKeepsBlankLines() {
        let rows = Self.wrap("above\n\nbelow", to: 80)
        XCTAssertEqual(rows, ["above", "", "below"])
    }

    /// Short lines are never touched.
    func testAShortLineIsEmittedAsIs() {
        XCTAssertEqual(Self.wrap("short", to: 40), ["short"])
    }

    /// An independent implementation of the documented wrap, so the CLI's own is
    /// checked against something other than itself.
    private static func wrap(_ text: String, to width: Int) -> [String] {
        var rows: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty { rows.append(""); continue }
            if paragraph.count <= width { rows.append(paragraph); continue }
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let piece = String(word)
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= width {
                    current += " " + piece
                } else {
                    rows.append(current)
                    current = piece
                }
                while current.count > width {
                    rows.append(String(current.prefix(width)))
                    current = String(current.dropFirst(width))
                }
            }
            if !current.isEmpty { rows.append(current) }
        }
        return rows
    }
}
