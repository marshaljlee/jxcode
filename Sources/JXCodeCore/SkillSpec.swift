import Foundation

// MARK: - The Agent Skills on-disk contract
//
// A skill used to be JXCode's own format, and JXCode was the only thing that
// read it. That stopped being true: skills are now an open standard that
// several agents read off disk by convention, and the moment a skill is
// *symlinked* into an agent's directory the agent parses the file itself. A
// file that JXCode is happy with and the agent rejects is a bind that looks
// applied and does nothing — the same class of silent failure this repo keeps
// finding and writing tests against.
//
// So the rules are written down here, once, from the agents' own documentation
// rather than from memory, and everything that writes or binds a skill checks
// against them.

/// What the agents actually require of a `SKILL.md`.
public enum SkillSpec {

    // MARK: - Names

    /// 1–64 characters.
    public static let maxNameLength = 64

    /// Lowercase alphanumerics with single interior hyphens.
    ///
    /// Quoted from the specification rather than approximated. The tempting
    /// version — "slugify it and be done" — is wrong in a way that matters:
    /// `Identifier.slug` keeps any `Character.isLetter`, so it passes `café`
    /// through untouched, and a non-ASCII name fails this pattern. That is not
    /// a hypothetical: it is the first thing a non-English author will type.
    public static let namePattern = "^[a-z0-9]+(-[a-z0-9]+)*$"

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength else { return false }
        return name.range(of: namePattern, options: .regularExpression) != nil
    }

    // MARK: - Descriptions

    /// The `description` is required, and it is the whole interface.
    ///
    /// An agent loads the description to decide whether to read the body, so a
    /// missing or vague one is not a cosmetic problem — it is the difference
    /// between a skill that gets used and one that never does.
    public static let minDescriptionLength = 1
    public static let maxDescriptionLength = 1024

    // MARK: - Reserved names

    /// Names an agent keeps for itself.
    ///
    /// `synced` is where Claude Code downloads skills from claude.ai, "in any
    /// capitalization", and it skips a skill authored at that name. The
    /// `anthropic-skills` namespace is reserved in every session, whether or
    /// not the user signs in. Writing either produces a skill that is present
    /// on disk, linked correctly, and never loaded — the worst shape a failure
    /// can take here, because every visible signal says it worked.
    public static let reservedNames: Set<String> = ["synced", "anthropic-skills"]

    public static func isReserved(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if reservedNames.contains(lowered) { return true }
        // `anthropic-skills:pdf` and the rest of the namespace. The colon is
        // what makes it a namespace rather than a name, and it is also why a
        // plain set membership test is not enough.
        return lowered.hasPrefix("anthropic-skills:")
    }

    /// The finding for a reserved name, or `nil` when the name is free.
    ///
    /// Shared by both checkers — the one that judges a value in memory and the
    /// one that judges a file on disk — so the wording cannot drift between
    /// them. A reserved name is a problem with the *id*, and the id is the same
    /// thing in both views.
    static func reservedFinding(_ id: String) -> Finding? {
        guard isReserved(id) else { return nil }
        return Finding(
            severity: .blocking,
            message: "“\(id)” is a name the agents reserve for themselves",
            fix: "rename it — a skill at a reserved name is skipped with a startup notice"
        )
    }

    /// The one description that cannot help: the skill's own name.
    ///
    /// Shared by both checkers, and reached two ways in each — an author who
    /// typed the name, and an author who typed nothing at all. The second is
    /// the one that surprises people, which is why the wording names the
    /// outcome rather than the input: "no description" describes what the
    /// author left out, while what the agent actually reads is the name.
    ///
    /// Advisory, and it has to be. A skill whose description is its name loads
    /// everywhere; it is simply never chosen. Blocking it would make the binder
    /// refuse a file no agent rejects, and would put the two checkers in
    /// disagreement about the same bytes.
    static func nameRepeatFinding(_ name: String) -> Finding {
        Finding(
            severity: .advisory,
            message: "the description is “\(name)”, which is the skill's own name",
            // No em-dash in the fix. `Finding.rendered` already joins the two
            // with one, and a fix containing its own reads as three clauses in
            // a single line — which is how this printed the first time it ran
            // against a real skill.
            fix: "say when to use it instead; the name is already in `name:` and "
                + "in the directory"
        )
    }

    // MARK: - Frontmatter fields

    /// The fields the specification recognises. Anything else is ignored by
    /// OpenCode and a hard error for the packaging/upload path, so JXCode
    /// writes only these.
    public static let recognisedFrontmatterKeys: Set<String> = [
        "name", "description", "license", "compatibility", "metadata", "allowed-tools",
    ]

    // MARK: - Findings

    public enum Severity: String, Sendable, Equatable {
        /// The skill will not load, or will not load everywhere. Worth refusing
        /// to bind natively over, because a native bind is a claim that the
        /// agent will find it.
        case blocking
        /// It loads. It just is not what the author meant.
        case advisory
    }

    public struct Finding: Sendable, Equatable {
        public let severity: Severity
        public let message: String
        /// What to do about it, when there is a specific answer. A finding
        /// without one is a complaint.
        public let fix: String?

        public init(severity: Severity, message: String, fix: String? = nil) {
            self.severity = severity
            self.message = message
            self.fix = fix
        }

        /// One line, for a report.
        public var rendered: String {
            let mark = severity == .blocking ? "✗" : "·"
            guard let fix else { return "\(mark) \(message)" }
            return "\(mark) \(message) — \(fix)"
        }
    }

    // MARK: - Checking a value

    /// Everything wrong with a skill JXCode holds in memory.
    ///
    /// The id is the directory, so a problem with the id is a problem with the
    /// file: the spec requires `name` to match the directory that contains
    /// `SKILL.md`, and JXCode's store names that directory after the id.
    public static func findings(for skill: Skill) -> [Finding] {
        var out: [Finding] = []

        if !Identifier.isSafePathComponent(skill.id) {
            out.append(Finding(
                severity: .blocking,
                message: "“\(skill.id)” cannot be used as a directory name",
                fix: "rename the skill so its id contains only letters, digits and hyphens"
            ))
        } else if !isValidName(skill.id) {
            out.append(Finding(
                severity: .blocking,
                message: "“\(skill.id)” is not a valid skill name, so the file will not load",
                fix: "the spec wants 1–64 characters of lowercase letters, digits and single "
                    + "hyphens (\(namePattern)), and the name has to match the directory it sits in"
            ))
        }

        if let reserved = reservedFinding(skill.id) {
            out.append(reserved)
        }

        let description = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty || description.lowercased() == skill.name.lowercased() {
            // One finding for two inputs, because they are one file.
            //
            // An absent summary is not a missing description: `rendered()`
            // writes the display name in its place, so what lands on disk is
            // `description: <name>` either way. This used to be reported as a
            // *blocking* "no description", which was wrong twice over. The file
            // loads, so no agent rejects it and the severity was simply not what
            // `Severity.blocking` means here; and the same skill reported only
            // an advisory after a restart, when the store had read the
            // name-as-description back off disk. `jxcode skill-add` therefore
            // called a skill blocking that `jxcode skill-check` called fine.
            out.append(nameRepeatFinding(skill.name))
        } else if description.count > maxDescriptionLength {
            out.append(Finding(
                severity: .blocking,
                message: "the description is \(description.count) characters; the limit is \(maxDescriptionLength)",
                fix: "move the detail into the body and leave the description as the reason to open it"
            ))
        }

        if skill.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(Finding(
                severity: .advisory,
                message: "the body is empty",
                fix: "the description alone gets the skill opened; there is nothing in it"
            ))
        }

        return out
    }

    public static func isBindable(_ skill: Skill) -> Bool {
        !findings(for: skill).contains { $0.severity == .blocking }
    }

    // MARK: - Checking a file

    /// What is wrong with a `SKILL.md` on disk, judged as the agent will judge it.
    ///
    /// Separate from `findings(for:)` because the two look at different things.
    /// The in-memory check cannot see the file's declared `name` — `Skill.name`
    /// is a *display* name, and `rendered()` deliberately writes the id there
    /// instead. This reads the raw text and applies the rule the spec states:
    /// the declared name must equal the directory.
    public static func findings(id: String, text: String) -> [Finding] {
        let (frontmatter, body) = Skill.splitFrontmatter(text)
        var out: [Finding] = []

        // Checked before the name, because it is a fact about the directory
        // rather than about the file: a reserved id is refused whether or not
        // the frontmatter inside it is well formed.
        if let reserved = reservedFinding(id) {
            out.append(reserved)
        }

        guard let declared = frontmatter["name"]?.trimmingCharacters(in: .whitespaces),
              !declared.isEmpty
        else {
            out.append(Finding(
                severity: .blocking,
                message: "the frontmatter declares no name",
                fix: "add `name: \(id)` — the name has to match the directory it sits in"
            ))
            return out
        }

        if declared != id {
            out.append(Finding(
                severity: .blocking,
                message: "the frontmatter says `name: \(declared)` but the directory is “\(id)”",
                fix: "they have to match; a display title belongs in the body, not in `name`"
            ))
        }

        if !isValidName(declared) {
            out.append(Finding(
                severity: .blocking,
                message: "`\(declared)` does not match \(namePattern)",
                fix: "lowercase letters, digits and single hyphens, 1–64 characters"
            ))
        }

        let description = frontmatter["description"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if description.isEmpty {
            out.append(Finding(
                severity: .blocking,
                message: "the frontmatter declares no description",
                fix: "an agent picks a skill by its description, so this one is never chosen"
            ))
        } else if description.count > maxDescriptionLength {
            out.append(Finding(
                severity: .blocking,
                message: "the description is \(description.count) characters; the limit is \(maxDescriptionLength)"
            ))
        } else if let restated = restatedName(of: description, declared: declared, body: body) {
            // The value checker's rule has to hold here too, or the two
            // disagree about the same file: `jxcode skill-check` would say a
            // name-shaped description loads everywhere while `jxcode shared`
            // said no agent will ever choose it. That disagreement was not
            // hypothetical — it was the reported state of every skill added
            // without `--description`, in three surfaces at once.
            out.append(nameRepeatFinding(restated))
        }

        // Claude Code reads frontmatter only when the opening fence is the
        // file's first line; otherwise it treats the whole file, fences
        // included, as content. JXCode's own parser is more forgiving, which is
        // exactly why the difference has to be reported here rather than
        // discovered by the agent.
        if let first = text.components(separatedBy: .newlines).first,
           !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           first.trimmingCharacters(in: .whitespacesAndNewlines) != "---" {
            out.append(Finding(
                severity: .blocking,
                message: "the frontmatter does not start on the first line",
                fix: "Claude Code only reads it when `---` is line one; anything above it makes "
                    + "the whole file skill content"
            ))
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(Finding(
                severity: .advisory,
                message: "the body is empty"
            ))
        }

        return out
    }

    /// The skill's own name that `description` restates, or `nil`.
    ///
    /// A description can repeat a name that lives in two places, and checking
    /// only one of them is how the file view missed the commonest mistake. The
    /// frontmatter `name` is the id, because the specification requires it to
    /// match the directory. The human-readable title is the body's first
    /// heading, which is where `Skill.rendered()` puts a display name — so a
    /// description copied from the title is a repeat that a comparison against
    /// the frontmatter alone would never see. `description: Release checklist`
    /// beside `name: release-checklist` and `# Release checklist` is the exact
    /// file `jxcode skill-add --name "Release checklist"` writes.
    private static func restatedName(
        of description: String,
        declared: String,
        body: String
    ) -> String? {
        var candidates = [declared]
        if let heading = Skill.firstHeading(in: body) { candidates.append(heading) }
        let lowered = description.lowercased()
        return candidates.first { !$0.isEmpty && $0.lowercased() == lowered }
    }

    /// The fields a file declares that the specification does not recognise.
    ///
    /// Advisory rather than blocking: the agents ignore unknown fields. The
    /// packaging and upload path does not — it fails hard — so a skill destined
    /// for claude.ai has to be clean.
    public static func unrecognisedFields(in text: String) -> [String] {
        let (frontmatter, _) = Skill.splitFrontmatter(text)
        return frontmatter.keys.filter { !recognisedFrontmatterKeys.contains($0) }.sorted()
    }
}

// MARK: - Asking a skill about itself

public extension Skill {

    /// Everything wrong with this skill, judged as an agent would judge it.
    ///
    /// A property rather than a function so it can be read where a skill is
    /// listed, which is where an author will actually notice it — a finding
    /// that only appears at bind time is a finding that arrives after the work
    /// is done.
    var findings: [SkillSpec.Finding] { SkillSpec.findings(for: self) }

    /// Whether this skill can be linked into an agent's own skill directory.
    ///
    /// Advisory findings do not block: a description that repeats the name is
    /// worth saying, not worth refusing over. A blocking one does, because a
    /// native bind is a claim that the agent will find the skill, and making
    /// that claim about a file the agent rejects is worse than not binding.
    var isBindableNatively: Bool { SkillSpec.isBindable(self) }
}
