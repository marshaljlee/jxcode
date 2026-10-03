import Foundation

/// Line-oriented editing of a text file that keeps its line endings.
///
/// `components(separatedBy: "\n")` followed by `joined(separator: "\n")` looks
/// like it puts back what it took apart, and for an LF file it does. For a CRLF
/// file it silently rewrites the whole thing: every `\r\n` comes back as `\n`,
/// so a bind or a revert returns different bytes than it read. That contradicts
/// the one promise these writers make — that everything outside the managed
/// region is preserved byte for byte — and a Markdown diff will not show it.
///
/// So a line here is stored **with** its terminator attached, and the split is
/// undone by joining with nothing. A file that mixes CRLF and LF comes back
/// exactly as it was, which normalising cannot manage at all.
public enum TextLines {

    /// Split `text` into lines that each keep their own terminator.
    ///
    /// A final line with no terminator is kept. A lone `\r` is treated as
    /// content rather than a terminator, so it survives too.
    /// Walked by scalar, not by `Character`: `\r\n` is **one** grapheme
    /// cluster, so a `Character` loop over a CRLF file never sees a lone `\r`
    /// and every test for one silently fails.
    public static func split(_ text: String) -> [String] {
        let scalars = text.unicodeScalars
        let lf: Unicode.Scalar = "\n"
        let cr: Unicode.Scalar = "\r"

        var lines: [String] = []
        var current = ""
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == lf {
                current.unicodeScalars.append(scalar)
                lines.append(current)
                current.removeAll(keepingCapacity: true)
            } else if scalar == cr {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == lf {
                    current.unicodeScalars.append(scalar)
                    current.unicodeScalars.append(scalars[next])
                    lines.append(current)
                    current.removeAll(keepingCapacity: true)
                    index = next
                } else {
                    current.unicodeScalars.append(scalar)
                }
            } else {
                current.unicodeScalars.append(scalar)
            }
            index = scalars.index(after: index)
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Put split lines back together. The inverse of `split`, including for a
    /// file that mixes terminators.
    public static func join(_ lines: [String]) -> String {
        lines.joined(separator: "")
    }

    /// A line without its terminator.
    ///
    /// One `dropLast()`, even for `\r\n`: a CRLF pair is a single `Character`,
    /// so dropping two removes the terminator *and* the last character of the
    /// line. `hasSuffix("\r\n")` still matches, which is what makes the two
    /// easy to get wrong together.
    public static func content(of line: String) -> String {
        if line.hasSuffix("\r\n") || line.hasSuffix("\n") || line.hasSuffix("\r") {
            return String(line.dropLast())
        }
        return line
    }

    /// The terminator `text` mostly uses, so the text we add matches the file.
    ///
    /// The majority, not every line: a mostly-LF file with one CRLF line pasted
    /// into it keeps that line's terminator (`split` preserves it) and gets LF
    /// for anything new. Picking the majority keeps a conversion from becoming
    /// a mix. A file with no line ending at all gets LF.
    public static func terminator(of text: String) -> String {
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let lf = text.replacingOccurrences(of: "\r\n", with: "")
            .components(separatedBy: "\n").count - 1
        // Strictly greater, not `>=`: a file with no line ending at all has
        // zero of each, and a tie has to fall to LF rather than to CRLF.
        return crlf > lf ? "\r\n" : "\n"
    }
}
