import Foundation

extension Data {

    /// How many bytes from the front may be decoded without cutting a UTF-8
    /// scalar in half.
    ///
    /// Flushing a byte buffer on a *size* threshold can sever a multi-byte
    /// scalar. `String(decoding:as: UTF8.self)` does not fail on such a cut —
    /// it substitutes U+FFFD for the fragment, and then substitutes U+FFFD
    /// again for the bytes that would have completed it when they arrive in the
    /// next chunk. One character goes in, two replacement characters come out,
    /// and it is permanent: the bytes were discarded as they were decoded.
    ///
    /// Splitting on a byte *value* needs none of this. Every byte of a
    /// multi-byte scalar is `0x80` or greater, and the separators streams are
    /// actually framed with (`0x0A`, `0x0D`) are not, so a cut at a newline is
    /// always aligned. It is only the volume-based fallback that can land in
    /// the middle of a character, because it cuts at a count rather than at a
    /// byte.
    ///
    /// A scalar is at most four bytes, so the answer depends only on the tail:
    /// find the byte that starts the last scalar, and if it promises more bytes
    /// than the buffer holds, stop before it and let those bytes arrive.
    public var utf8ScalarPrefixLength: Int {
        guard !isEmpty else { return 0 }

        // Continuation bytes carry the top two bits `10`. Walking back over
        // them reaches the byte that starts the final scalar; a scalar is at
        // most four bytes, so this is at most three steps.
        var start = count - 1
        var continuations = 0
        while start > 0, continuations < 3, self[start] & 0xC0 == 0x80 {
            start -= 1
            continuations += 1
        }

        let lead = self[start]
        let length: Int
        if lead < 0x80 { length = 1 }              // ASCII
        else if lead < 0xC0 { length = 1 }          // a continuation with no lead byte
        else if lead < 0xE0 { length = 2 }
        else if lead < 0xF0 { length = 3 }
        else if lead < 0xF8 { length = 4 }
        else { length = 1 }                         // not a legal lead byte

        // The last scalar is whole only if every byte it declares is present.
        // A stray continuation byte is counted as whole: the input is not UTF-8
        // at that point, so there is no boundary to protect, and holding it
        // back would stall the buffer on bytes that can never become valid.
        return start + length <= count ? count : start
    }
}
