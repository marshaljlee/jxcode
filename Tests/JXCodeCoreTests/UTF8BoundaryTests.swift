import XCTest
@testable import JXCodeCore

/// Flushing a byte buffer on a size threshold is only safe when the cut lands
/// between scalars. These cover the arithmetic; the router test covers what a
/// real stream does when it is cut there.
final class UTF8BoundaryTests: XCTestCase {

    private func length(of text: String) -> Int {
        Data(text.utf8).utf8ScalarPrefixLength
    }

    func testASCIIIsWhollyDecodable() {
        XCTAssertEqual(length(of: "hello"), 5)
    }

    func testEmptyBufferHasNothingToFlush() {
        XCTAssertEqual(Data().utf8ScalarPrefixLength, 0)
    }

    /// A complete scalar at the tail is included — this is the case that must
    /// not regress while fixing the one below.
    func testACompleteTrailingScalarIsIncluded() {
        XCTAssertEqual(length(of: "ab中"), 5)      // 2 + 3
        XCTAssertEqual(length(of: "ab🙂"), 6)      // 2 + 4
    }

    /// The case this exists for: the buffer ends part-way through a scalar, so
    /// those bytes have to wait for the rest instead of being decoded now.
    func testAnIncompleteTrailingScalarIsHeldBack() {
        let emoji = Array("🙂".utf8)               // four bytes
        for prefix in 1..<emoji.count {
            let data = Data("ab".utf8) + Data(emoji.prefix(prefix))
            XCTAssertEqual(data.utf8ScalarPrefixLength, 2, "\(prefix) of 4 bytes present")
        }
    }

    /// A three-byte scalar holds back two bytes, not three: the cut goes before
    /// the lead byte, wherever in the scalar the buffer happens to end.
    func testAHeldBackScalarIsHeldBackInFull() {
        let scalar = Array("中".utf8)              // three bytes
        for prefix in 1..<scalar.count {
            let data = Data("ab".utf8) + Data(scalar.prefix(prefix))
            XCTAssertEqual(data.utf8ScalarPrefixLength, 2, "\(prefix) of 3 bytes present")
        }
    }

    /// The invariant, stated directly rather than through examples: whatever
    /// length comes back, decoding that prefix and re-encoding it must return
    /// the same bytes. A substitution changes them, because U+FFFD is three
    /// bytes and the fragment it replaces is one, two or three.
    func testTheReturnedPrefixAlwaysRoundTrips() {
        let samples = ["", "a", "ab中", "a🙂b", "日本語テキスト", "a\r\n🙂", "🙂🙂🙂"]
        for sample in samples {
            for cut in 0...sample.utf8.count {
                let data = Data(sample.utf8.prefix(cut))
                let safe = data.utf8ScalarPrefixLength
                let decoded = String(decoding: data.prefix(safe), as: UTF8.self)
                XCTAssertEqual(
                    Array(decoded.utf8), Array(data.prefix(safe)),
                    "\(sample.debugDescription) cut at \(cut), flushed \(safe)"
                )
            }
        }
    }

    /// Input that is not UTF-8 at all must still make progress. A stray
    /// continuation byte is let through rather than held back for a lead byte
    /// that is never coming.
    func testGarbageStillMakesProgress() {
        XCTAssertEqual(Data([0x80, 0x80, 0x80]).utf8ScalarPrefixLength, 3)
    }
}
