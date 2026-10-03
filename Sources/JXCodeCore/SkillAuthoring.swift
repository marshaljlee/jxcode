import Foundation

// MARK: - Authoring help
//
// `SkillSpec` answers exactly one question: will this file load? That is the
// question a binder has to answer before it can claim an agent will find a
// skill, so every finding in it is decidable from the bytes and every blocking
// one means "an agent will reject this".
//
// That is not the question an author has. An author's question is "is this a
// good description?", and the answer is not a finding — a description can be
// perfectly loadable and still be the reason the skill is never chosen. Keeping
// the two apart is the whole point of this type. A finding says what is wrong
// with the file; this says what a good one looks like, which is a different
// sentence for a different reader, and it never refuses anything.
//
// Why it matters, in the standard's own terms: **progressive disclosure**. An
// agent loads the `description` of every bound skill up front and reads a body
// only when a description gives it a reason to. So the description is not a
// title — it is the routing key. It is also paid for in every session of every
// agent whether or not the skill is ever used, which is what makes the failing
// version of it so expensive: a description that restates the name spends that
// context and buys no routing at all.
//
// Three rules, deliberately. A longer list stops being advice and starts being
// a style guide, and a style guide an author skims is worth less than three
// rules an author reads.

public enum SkillAuthoring {

    /// One thing a description has to do, with the version that fails and the
    /// version that works.
    ///
    /// The bad/good pair is the content, not decoration. A rule stated without
    /// an example is a rule an author agrees with and then violates anyway,
    /// because the failing version reads fine while you are the one writing it.
    public struct Rule: Sendable, Equatable {
        /// The rule, one line.
        public let headline: String
        /// Why it is the rule — the mechanism, not the preference.
        public let because: String
        /// What the naive version writes. Empty for a rule about absence,
        /// which has no text to show.
        public let bad: String
        /// What to write instead.
        public let good: String

        /// The ✗/✓ pair, for a surface that has room for both. The failing
        /// line is omitted when there is nothing to show.
        public var examples: [String] {
            (bad.isEmpty ? [] : ["✗ \(bad)"]) + ["✓ \(good)"]
        }

        /// The rule and the version that works, on one line — for a form that
        /// is being filled in and has no room for a paragraph.
        public var oneLine: String { "\(headline) — \(good)" }
    }

    /// All three good examples are the same sentence, on purpose.
    ///
    /// It is one line that satisfies every rule at once, so an author who
    /// writes it has nothing left to check — and an author who notices that is
    /// an author who has understood the point rather than memorised three
    /// separate instructions.
    public static let workedExample =
        "Use before tagging a release, to run the suite and write the notes"

    public static let rules: [Rule] = [
        Rule(
            headline: "Say when to use it, not what it is called",
            because: "An agent reads the description to decide whether to open the "
                + "body, so a description that only names the skill gives it nothing "
                + "to decide with.",
            bad: "Release checklist",
            good: workedExample
        ),
        Rule(
            headline: "Keep it to one sentence",
            because: "Progressive disclosure cuts one way: the description is in "
                + "context from the first token of every session in every agent, and "
                + "the body is not. A description that runs to a paragraph is a body "
                + "that is always loaded.",
            bad: "A skill for releases. It covers the suite, the changelog, the "
                + "version bump, the tag, the notes, and the order to do them in, "
                + "plus what to do when the suite fails and how to roll back a tag "
                + "that has already been pushed.",
            good: workedExample
        ),
        Rule(
            headline: "Never leave it empty",
            because: "A skill is written with a description whether or not the author "
                + "gave one, so an absent description is not a gap an agent skips "
                + "over: it becomes the name, which is the one description that cannot "
                + "tell an agent anything.",
            bad: "",
            good: workedExample
        ),
    ]

    /// The paragraph that explains why the description is the whole interface.
    ///
    /// One place, so the CLI and the pane cannot drift into saying it
    /// differently — the same reason `SkillSpec.Finding.rendered` exists.
    public static let progressiveDisclosure =
        "An agent loads the description of every skill before it reads any of "
        + "their bodies, and opens a body only when a description gives it a "
        + "reason to. So the description is not a title, it is the routing key — "
        + "and unlike the body, it is in context in every session of every agent, "
        + "whether or not the skill is ever used."

    /// The rule most worth showing for a description being written, or `nil`
    /// when the description already does its job.
    ///
    /// `nil` is the common answer and it is a real one: advice that fires on a
    /// good description is advice an author learns to ignore. Each predicate
    /// below is decidable from the text, and the list is short for the same
    /// reason the rule list is — a longer one would start flagging descriptions
    /// that are perfectly good.
    public static func advice(name: String, description: String) -> Rule? {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing typed. The one case where the outcome is decided for the
        // author rather than by them.
        if description.isEmpty { return rules[2] }

        // Over the limit is already a blocking finding; the useful thing to say
        // about it is why the limit exists.
        if description.count > SkillSpec.maxDescriptionLength { return rules[1] }

        // The name, in any capitalization — and its slug, because that is what
        // the directory will be called and what the author is most likely to
        // have copied.
        let lowered = description.lowercased()
        if !name.isEmpty, lowered == name.lowercased() { return rules[0] }
        if lowered == Identifier.slug(name, fallback: "") { return rules[0] }

        // A description about the skill rather than about the task. Kept to a
        // short list of openers on purpose: "Use this skill when…" is a good
        // description, and a longer list of prefixes would flag it.
        for opener in ["this skill", "a skill that", "this is a skill"] where
            lowered.hasPrefix(opener) {
            return rules[0]
        }

        return nil
    }
}

// MARK: - The help, as both surfaces render it

public extension SkillAuthoring {

    /// The help as a block of terminal text.
    ///
    /// Laid out here rather than in the command, for the same reason the rules
    /// live here: the pane and the CLI have to be reading the same three rules
    /// and the same examples, and a second copy of this text in the GUI is how
    /// two surfaces start disagreeing about one skill.
    ///
    /// Wrapped by hand because a terminal does not wrap for us, and the bad
    /// examples are long on purpose — a short one does not look like the
    /// mistake it is describing. A break landing inside one of those sentences
    /// is a break inside the thing the author is comparing against.
    static var helpText: String {
        var lines = ["A skill's description is the whole interface.", ""]
        lines += wrap(progressiveDisclosure, indent: "  ", width: 76)
        lines.append("")

        for (index, rule) in rules.enumerated() {
            lines.append("  \(index + 1). \(rule.headline)")
            lines += wrap(rule.because, indent: "     ", width: 76)
            for example in rule.examples {
                lines += wrap(example, indent: "       ", width: 76)
            }
            if index < rules.count - 1 { lines.append("") }
        }

        lines.append("")
        lines.append("  Judge a skill you already have with: jxcode skill-check")
        return lines.joined(separator: "\n")
    }

    /// The rules as a tooltip — the whole set, for a surface with no room.
    ///
    /// The pane cannot afford three rules and two examples under a text field,
    /// so it carries the same text here and shows one rule inline. A tooltip is
    /// this app's idiom for "the explanation is available, not in the way".
    static var tooltip: String {
        let body = rules.map { "• \($0.headline)\n  ✓ \($0.good)" }
        return ([progressiveDisclosure] + body).joined(separator: "\n\n")
    }

    /// The one line to show for a description being written, or `nil`.
    ///
    /// `nil` is the common answer and a real one: advice that fires on a good
    /// description is advice an author learns to ignore. Both surfaces call
    /// this rather than reaching for `advice` themselves, so the CLI's hint and
    /// the pane's cannot word the same rule differently.
    static func hint(name: String, description: String) -> String? {
        advice(name: name, description: description)?.oneLine
    }

    /// Wrap `text` to `width` columns, with `indent` on every line.
    ///
    /// Splits on spaces and nothing else. A general wrapper would hyphenate or
    /// break inside a word, and every string this is used on is prose the
    /// author is meant to read as prose.
    private static func wrap(_ text: String, indent: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width - indent.count {
                current += " " + word
            } else {
                lines.append(indent + current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(indent + current) }
        return lines
    }
}
