import Foundation

/// Markers delimiting a region of a file that JXCode owns and rewrites.
///
/// The collection writes into files the user also owns — `CLAUDE.md`,
/// `AGENTS.md`, `settings.json`. Rewriting such a file wholesale would delete
/// whatever the user had put there, so every write is scoped to a fenced
/// region and everything outside it is preserved byte for byte.
///
/// Two shapes are needed because two file formats are involved: comments for
/// Markdown, and object keys for JSON.
public enum ManagedBlock {

    /// A start/end marker pair.
    public struct Markers: Sendable, Hashable {
        public let start: String
        public let end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }

        /// Markdown/HTML comment markers, which render as nothing in a
        /// Markdown preview.
        public static let markdownSkills = Markers(
            start: "<!-- >>> jxcode skills >>> -->",
            end: "<!-- <<< jxcode skills <<< -->"
        )

        /// TOML comment markers, for the connector tables in Codex's config.
        ///
        /// Distinct from the router block's markers so the two managed regions
        /// cannot delete each other: both live in `config.toml`, and both are
        /// rewritten independently.
        public static let tomlConnectors = Markers(
            start: "# >>> jxcode connectors >>>",
            end: "# <<< jxcode connectors <<<"
        )
    }

    // MARK: - Text files

    public static func contains(_ text: String, markers: Markers) -> Bool {
        text.contains(markers.start)
    }

    /// Remove the fenced region the way it was written, leaving the rest of the
    /// file byte for byte.
    ///
    /// There used to be a second variant here that trimmed the result and
    /// collapsed runs of blank lines, on the theory that the collapse only
    /// touched the gap our block left behind. It did not: it collapsed *every*
    /// blank run in the file, including the user's own, so a re-bind quietly
    /// ate a line of their text and revert could not put it back. Both the write
    /// path and the revert path now use this one, and the collapsing variant is
    /// gone rather than left lying around — the entire bug family came from
    /// having two behaviours available and picking the wrong one.
    ///
    /// The writers put exactly one blank line between the block and the body —
    /// `block + "\n\n" + body` or `body + "\n\n" + block` — so this takes that
    /// one with it, on whichever side the block sits. Anything further is the
    /// user's and stays. The result keeps its trailing newline, so callers must
    /// **not** append one.
    public static func removingPreservingShape(from text: String, markers: Markers) -> String {
        guard text.contains(markers.start) else { return text }

        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(markers.start) }),
              let end = lines.firstIndex(where: { $0.contains(markers.end) }),
              start <= end
        else { return text }

        var lower = start
        var upper = end
        if lower > 0, lines[lower - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lower -= 1
        } else if upper + 1 < lines.count,
                  lines[upper + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            upper += 1
        }

        lines.removeSubrange(lower...upper)
        return lines.joined(separator: "\n")
    }

    /// Put `block` at the top of `text`, replacing any previous block.
    ///
    /// At the top rather than the bottom because these files are read as
    /// instructions and the managed region is the part the app guarantees;
    /// burying it under an arbitrary amount of the user's own notes would make
    /// it effectively invisible.
    public static func inserting(
        _ block: String,
        into text: String,
        markers: Markers
    ) -> String {
        let body = removingPreservingShape(from: text, markers: markers)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return block + "\n"
        }
        return block + "\n\n" + body + "\n"
    }

    /// Put `block` at the end of `text`, replacing any previous block.
    ///
    /// Needed for TOML. A `[table]` header ends the top-level key section, so a
    /// block containing tables must come *after* every one of the user's own
    /// top-level assignments — putting it first would make their file invalid
    /// rather than merely reordered.
    public static func appending(
        _ block: String,
        to text: String,
        markers: Markers
    ) -> String {
        let body = removingPreservingShape(from: text, markers: markers)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return block + "\n"
        }
        return body + "\n\n" + block + "\n"
    }
}

/// Failures the shared collection can report.
public enum SharedCollectionError: Error, CustomStringConvertible {
    case unreadableJSON
    case missingSkill(String)
    case unknownAgent(String)

    public var description: String {
        switch self {
        case .unreadableJSON:
            return "the existing file is not a JSON object, so it was left alone"
        case .missingSkill(let id):
            return "no skill has the id `\(id)`"
        case .unknownAgent(let id):
            return "no agent has the id `\(id)`"
        }
    }
}
