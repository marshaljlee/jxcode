import Darwin
import Foundation

/// Every line the CLI prints, inside a margin on all four sides.
///
/// The CLI's output used to start in column 0 and run to the window edge. On a
/// terminal with a visible border — or any background that is not the default —
/// the first character sat against the glass and the last column of a long line
/// did the same on the other side, so the output read as clipped rather than as
/// a panel.
///
/// The first attempt fixed only the left side, which is the half that is easy
/// and visible in a screenshot. The other three were left: no blank line above
/// the first row, no blank line below the last, and long lines still ran to
/// column 80 and wrapped against the edge. All four now:
///
/// | Edge | How |
/// |---|---|
/// | top | one blank line before the first output |
/// | left | `margin` spaces on every row |
/// | right | rows wrap at the terminal width less the margins |
/// | bottom | one blank line when the process ends |
///
/// **Pipes get none of it.** A consumer reading stdout must not find a blank
/// line, two stray leading spaces, or a re-wrapped line in the middle of its
/// data — that breaks JSON, NDJSON, and `grep` alike. So the whole margin is
/// gated on `isatty(1)`, and `jxcode run --json | …` is byte-for-byte what it
/// was before any of this.
///
/// The bottom margin is installed with `atexit` rather than at the end of
/// `main`, because the CLI has many exits — `exit(2)` for an unknown command,
/// `exit(1)` for a refusal, and the fall-through at the bottom — and a margin
/// that only appears on the success path is a margin that is missing exactly
/// when a command has failed, which is when someone is looking at the screen.
enum Console {

    /// Blank rows above the first output and below the last.
    static let edgeRows = 1

    /// Columns of margin left of ordinary output, and the minimum kept clear on
    /// the right. Two is enough to read as a panel and few enough to leave a
    /// narrow terminal usable.
    static let marginColumns = 2
    static let margin = String(repeating: " ", count: marginColumns)

    /// Whether standard output is going to a terminal.
    ///
    /// `isatty(1)` rather than a guess from `ProcessInfo`, because the two
    /// disagree exactly where it matters — a launchd job and a CI runner both
    /// look like a normal process to `ProcessInfo` and both are pipes.
    static let isTTY: Bool = isatty(1) == 1

    /// Usable width for one row: the terminal's columns less both margins.
    ///
    /// Falls back to 80 when the size cannot be read, which is what a pipe gets
    /// and what a terminal reports before it has a size — and a wrap width that
    /// is wrong in the "no limit known" direction must not be a wrap width of
    /// zero, which would emit one character per line.
    static var usableWidth: Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return 80
        }
        return max(24, Int(size.ws_col) - marginColumns * 2)
    }

    // MARK: - The frame

    /// Emitted once, before anything else, the first time this process writes.
    ///
    /// A `static let` is initialised on first access, which makes it the
    /// earliest possible moment without every call site having to remember. It
    /// also installs the `atexit` hook that writes the bottom row, so the two
    /// halves of the frame are set up by the same lazy initialiser and cannot
    /// end up installed independently.
    private static let frame: Void = {
        guard isTTY else { return }
        blankLines(edgeRows)
        atexit {
            // A no-capture closure, so it converts to a C function pointer and
            // `atexit` will accept it.
            blankLines(Console.edgeRows)
        }
    }()

    /// Force the frame to exist even if the process somehow writes nothing.
    static func begin() { _ = frame }

    // MARK: - Printing

    /// Print one line, inside the margin when the output is a terminal.
    ///
    /// Accepts the same arguments as `print`, so every call site reads the same
    /// as it did before — which is why this is a drop-in for `print` rather than
    /// a new vocabulary.
    static func line(_ items: Any..., separator: String = " ") {
        let text = items.map { String(describing: $0) }.joined(separator: separator)
        emit(text)
    }

    /// Print without the margin — for box drawing and anything that carries its
    /// own left edge.
    static func raw(_ text: String) {
        write(text, prefix: "", wrap: false)
    }

    /// Print blank rows. No trailing spaces: a row of blanks with a margin on it
    /// is whitespace a user can select and copy.
    static func blank(_ count: Int = 1) {
        for _ in 0..<count { write("", prefix: "", wrap: false) }
    }

    /// Print to standard error, with the left margin but no frame.
    ///
    /// Errors get the margin because an error is the one line a person reads
    /// when something went wrong, and it is the line most likely to be the only
    /// thing on the screen. They do **not** get the blank rows: stderr is
    /// frequently interleaved with a program's own output, and a blank line
    /// arriving in the middle of someone else's stream is worse than a missing
    /// margin.
    ///
    /// Never touches stdout, because a consumer reading a pipe must not have an
    /// error's margin land in the middle of its data.
    static func error(_ text: String) {
        guard isTTY else {
            FileHandle.standardError.write(Data((text + "\n").utf8))
            return
        }
        for row in wrap(text, to: usableWidth) {
            FileHandle.standardError.write(Data((margin + row + "\n").utf8))
        }
    }

    /// A heading. Weight, not colour — the CLI is read over SSH and into logs.
    static func heading(_ text: String) {
        line(text)
    }

    /// `label   value`, with the label in a fixed column.
    static func field(_ label: String, _ value: String, width: Int = 16) {
        let padded = label.count < width
            ? label + String(repeating: " ", count: width - label.count)
            : label + " "
        line(padded + value)
    }

    // MARK: - Internals

    private static func emit(_ text: String) {
        _ = frame
        write(text, prefix: isTTY ? margin : "", wrap: isTTY)
    }

    private static func blankLines(_ count: Int) {
        for _ in 0..<count {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// Write `text`, prefixing every row it contains.
    ///
    /// Splitting on newlines rather than only prefixing the first is the whole
    /// point: a message assembled from a multi-line description would otherwise
    /// get a margin on its first line and sit flush against the edge on the next
    /// five.
    private static func write(_ text: String, prefix: String, wrap shouldWrap: Bool) {
        let rows = shouldWrap
            ? wrap(text, to: usableWidth)
            : text.components(separatedBy: "\n")
        for row in rows {
            FileHandle.standardOutput.write(Data((prefix + row + "\n").utf8))
        }
    }

    /// Break `text` into rows no wider than `width`, on word boundaries where
    /// it can and mid-word only where it must.
    ///
    /// A path or a URL has no spaces, so a naive word wrap would leave one
    /// enormous "word" running off the edge — which is the exact case the right
    /// margin exists to prevent. So an over-long word is hard-broken.
    ///
    /// Existing newlines are honoured first: a caller that already laid out a
    /// block gets each of its rows wrapped, never re-flowed into one paragraph.
    private static func wrap(_ text: String, to width: Int) -> [String] {
        var rows: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty {
                rows.append("")
                continue
            }
            if paragraph.count <= width {
                rows.append(paragraph)
                continue
            }
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
                // A single word longer than the row: break it.
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
