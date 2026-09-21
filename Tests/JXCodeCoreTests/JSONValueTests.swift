import XCTest
@testable import JXCodeCore

/// Numbers that cannot be an `Int`.
///
/// `Int(_:)` on a `Double` traps — on infinity, on NaN, and on any finite value
/// outside `Int`'s range. A JSON number is a `Double` with no range guarantee
/// whatever, and two of the places they come from are outside our control: a
/// local model server filling in `/props`, and a model filling in a tool-call
/// argument.
final class JSONValueTests: XCTestCase {

    // MARK: intValue

    func testIntValueIsNilWhereIntWouldTrap() {
        // Finite but outside `Int`'s range. This is the reachable one: a JSON
        // document may legitimately contain 1e30, and `Int(1e30)` traps.
        XCTAssertNil(JSONValue.number(1e30).intValue)
        XCTAssertNil(JSONValue.number(-1e30).intValue)
        XCTAssertNil(JSONValue.number(1e300).intValue)
        // `Double(Int.max)` rounds up to 2^63, one past the largest `Int`.
        XCTAssertNil(JSONValue.number(Double(Int.max)).intValue)

        // Non-finite.
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(-.infinity).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
    }

    /// The fix must not quietly change what a normal number converts to.
    func testIntValueStillTruncates() {
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
        XCTAssertEqual(JSONValue.number(0).intValue, 0)
        XCTAssertEqual(JSONValue.number(-7).intValue, -7)
        XCTAssertEqual(JSONValue.number(3.7).intValue, 3)
        XCTAssertEqual(JSONValue.number(-3.7).intValue, -3)
        XCTAssertEqual(JSONValue.number(1e18).intValue, 1_000_000_000_000_000_000)
    }

    func testIntValueIsNilForNonNumbers() {
        XCTAssertNil(JSONValue.string("42").intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
        XCTAssertNil(JSONValue.null.intValue)
    }

    // MARK: flattenedText

    /// A whole number is written without a fractional part — except when there
    /// is no `Int` that holds it, where `String(value)` is the only rendering
    /// that does not take the process down.
    func testFlattenedTextRendersNumbersThatDoNotFit() {
        XCTAssertEqual(JSONValue.number(42).flattenedText, "42")
        XCTAssertEqual(JSONValue.number(3.5).flattenedText, "3.5")
        XCTAssertEqual(JSONValue.number(0).flattenedText, "0")
        XCTAssertEqual(JSONValue.number(1e30).flattenedText, "1e+30")
        XCTAssertEqual(JSONValue.number(.infinity).flattenedText, "inf")
        XCTAssertEqual(JSONValue.number(-.infinity).flattenedText, "-inf")
        XCTAssertEqual(JSONValue.number(.nan).flattenedText, "nan")
    }

    /// Flattening was the trap reachable from a model-authored tool argument:
    /// `JSONValue.parse` of `{"n": 1e30}` and then reading the text of it.
    func testFlatteningAModelAuthoredNumberDoesNotTrap() {
        let argument = JSONValue.parse("{\"n\": 1e30}")
        XCTAssertEqual(argument.objectValue?["n"]?.numberValue, 1e30)
        XCTAssertEqual(argument.flattenedText.contains("1e+30"), true)
    }

    // MARK: What a decoded document actually gives

    /// A number too large for a `Double` is rejected by the decoder outright,
    /// so the whole document comes back as `.null`.
    ///
    /// Worth pinning, because it is the difference between the crash described
    /// in the review and the one that exists. `1e999` cannot reach `Int(_:)`
    /// through `JSONDecoder`; `1e30` can, because it fits a `Double` and does
    /// not fit an `Int`.
    func testANumberTooLargeForADoubleIsRejectedByTheDecoder() {
        XCTAssertEqual(JSONValue.parse("{\"n\": 1e999}"), JSONValue.null)
        XCTAssertEqual(JSONValue.parse("[1e999]"), JSONValue.null)
    }

    /// The one that does get through, and used to trap.
    func testADecodedOutOfRangeNumberConvertsToNil() {
        let document = JSONValue.parse("{\"n_ctx\": 1e30}")
        XCTAssertNotNil(document.objectValue, "1e30 is a valid JSON number; the document decodes")
        XCTAssertNil(document.objectValue?["n_ctx"]?.intValue)
    }

    // MARK: The conversion itself

    func testSafelyTruncatingMatchesIntWhereIntDoesNotTrap() {
        for value in [0.0, 1.0, -1.0, 42.0, 3.7, -3.7, 1e18, 1e15] {
            XCTAssertEqual(Int(safelyTruncating: value), Int(value), "\(value)")
        }
    }

    func testSafelyTruncatingIsNilWhereIntTraps() {
        XCTAssertNil(Int(safelyTruncating: .infinity))
        XCTAssertNil(Int(safelyTruncating: -.infinity))
        XCTAssertNil(Int(safelyTruncating: .nan))
        XCTAssertNil(Int(safelyTruncating: 1e300))
        XCTAssertNil(Int(safelyTruncating: Double(Int.max)))
        XCTAssertNil(Int(safelyTruncating: Double(Int.min) * 2))
    }
}
