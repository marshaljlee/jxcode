import Foundation

// MARK: - A secret is named, not written
//
// One connector definition is rendered into four agents' configs. A value
// written verbatim therefore exists in four files at once: four places to leak
// from, four places to rotate, and four chances for one of them to be committed
// by accident. The fix is not to encrypt anything — it is to stop writing the
// value down and write the *name* of the thing that holds it instead.
//
// Every agent that expands anything agrees on the shape and disagrees on the
// spelling, which is the whole reason this is a type with a translation table
// rather than a string substitution at each writer:
//
// | Agent | Reference form | Where that came from |
// |---|---|---|
// | Claude Code | `${GITHUB_TOKEN}` | config `${VAR}` expansion, in 2.1.284 |
// | Gemini CLI | `${GITHUB_TOKEN}` | documented for the MCP `env` block |
// | opencode | `{env:GITHUB_TOKEN}` | its own docs say the shell form is **not** substituted |
// | Codex | — | TOML has no expansion of any kind |
//
// So the canonical form — the one stored in `shared/connectors/<id>/connector.json`
// and the one both surfaces ask the user to write — is the shell form. A value
// that already carries opencode's spelling is accepted on the way in as well,
// because that is the form someone copying from a working opencode config will
// arrive with, and there is no reason to make them retype it.

/// The syntax one agent expands inside a config value.
public enum CredentialSyntax: Sendable, Equatable, CaseIterable {
    /// `${NAME}` — the canonical form, and what Claude Code and Gemini expand.
    case shell
    /// `{env:NAME}` — opencode's form, which is *not* the shell form.
    case opencode

    /// Render a reference in this syntax.
    ///
    /// One method, and that is the whole of the type. `example` and `because`
    /// lived here for a while and nothing called either — an example is
    /// `render("GITHUB_TOKEN")`, and the reason each spelling is what it is
    /// belongs in the header table above and in the entry writers, which are
    /// the places a reader meets the difference.
    public func render(_ name: String) -> String {
        switch self {
        case .shell:    return "${\(name)}"
        case .opencode: return "{env:\(name)}"
        }
    }
}

/// A value that names where a secret lives instead of holding it.
///
/// Two input forms are recognised, anywhere inside a value — `Bearer ${TOKEN}`
/// is a reference in a value that is mostly a literal, which is how the
/// header-shaped case actually looks. Everything else is a literal.
///
/// A bare `$NAME` is deliberately *not* one of the two. `$` followed by
/// letters is not distinguishable from prose — `Costs $USD per call` contains
/// one — and a rule that guesses at that would turn a header value into a
/// broken reference, or a broken reference into a literal, depending on the
/// sentence. The two accepted forms are unambiguous, and the message that
/// refuses a literal says which to write.
public enum CredentialReference {

    /// Whether `name` can be a reference at all.
    ///
    /// The same shape a shell accepts for a variable name, because that is what
    /// the agents expand: a letter or underscore, then letters, digits or
    /// underscores.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 128 else { return false }
        guard first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Every variable named anywhere inside `value`, in order, without repeats.
    public static func names(in value: String) -> [String] {
        var found: [String] = []
        var index = value.startIndex
        while index < value.endIndex {
            guard let match = match(in: value, at: index) else {
                index = value.index(after: index)
                continue
            }
            if !found.contains(match.name) { found.append(match.name) }
            index = match.end
        }
        return found
    }

    /// Whether `value` names a secret rather than holding one.
    public static func isReference(_ value: String) -> Bool {
        !names(in: value).isEmpty
    }

    /// Rewrite every reference in `value` into `syntax`, leaving the rest of
    /// the value byte-for-byte alone.
    ///
    /// The surrounding text is kept on purpose: a header is usually
    /// `Bearer ${TOKEN}`, and a rewrite that replaced the whole value would
    /// lose the scheme the server expects.
    public static func rewrite(_ value: String, to syntax: CredentialSyntax) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard let match = match(in: value, at: index) else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            result += syntax.render(match.name)
            index = match.end
        }
        return result
    }

    /// The reference that starts at `index`, or `nil`.
    ///
    /// Hand-rolled rather than a regular expression, because the two forms have
    /// different delimiters and a name character set that has to be validated
    /// either way — a pattern that accepted `${}` or `${a b}` would turn a
    /// literal into a reference, and the whole value of this type is that it
    /// never does that.
    private static func match(
        in value: String,
        at index: String.Index
    ) -> (name: String, end: String.Index)? {
        for (prefix, nameOffset) in [("${", 2), ("{env:", 5)] {
            guard value[index...].hasPrefix(prefix) else { continue }
            let start = value.index(index, offsetBy: nameOffset)
            guard let close = value[start...].firstIndex(of: "}") else { return nil }
            let name = String(value[start..<close])
            guard isValidName(name) else { return nil }
            return (name, value.index(after: close))
        }
        return nil
    }

    /// A variable name derived from a key, for a message that has to suggest one.
    ///
    /// `Authorization` becomes `AUTHORIZATION` and `api-key` becomes `API_KEY`.
    /// It is a suggestion and not a rule: the header a connector needs is
    /// usually not named after the header, which is why the message says the
    /// name is the user's to choose.
    public static func suggestedVariableName(for key: String) -> String {
        var out = ""
        for scalar in key.unicodeScalars {
            switch scalar.value {
            case 65...90, 48...57:  out.unicodeScalars.append(scalar)
            case 97...122:          out += String(Character(scalar)).uppercased()
            default:                out += "_"
            }
        }
        let collapsed = out
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        guard !collapsed.isEmpty else { return "TOKEN" }
        // A name may not start with a digit, and a key like `2fa-token` would.
        return collapsed.first?.isNumber == true ? "_" + collapsed : collapsed
    }
}

// MARK: - Catching the literal

/// Whether a connector value holds a secret outright.
///
/// The rule is not invented here. It is the one Claude Code 2.1.284 applies to
/// the header values in a plugin's MCP config, read out of the installed binary
/// and ported with its constants intact, because the point of refusing a value
/// is that the agent it is written *to* would object to it as well. Ported:
///
/// - eight shapes that are a secret whatever the key is called — `sk-…`,
///   `ghp_…`, `github_pat_…`, `xoxb-…`, `AKIA…`, `glpat-…`, `AIza…`, a JWT;
/// - the key must look credential-ish: `authorization`, `api-key`, `api_key`,
///   `token`, `secret`, `password`, `credential`;
/// - the value must survive: over 8192 characters is not a value, and anything
///   containing `your-`, `example`, `changeme`, `placeholder`, `dummy`,
///   `redacted`, `xxx`, `<>` or `***` is a placeholder somebody meant to
///   replace;
/// - after stripping a `Bearer` / `Basic` / `Token` / `Bot` scheme, the
///   candidate must be at least 20 characters, contain no whitespace, and carry
///   at least 3 bits per character of Shannon entropy — which is what separates
///   a key from a word.
///
/// **One deliberate widening.** Claude Code exempts a value containing `${…}`.
/// That exemption is not enough here, because opencode's reference form is
/// `{env:…}` and a naive port flags it: `{env:MY_LONG_VARIABLE_NAME}` is 28
/// characters, has no whitespace, and is high-entropy, so under the upstream
/// rule it *is* a literal credential. Every form this type accepts is exempt,
/// which is the one place the port is not literal.
public enum CredentialScan {

    /// Which half of a connector a value came from.
    public enum Field: String, Sendable, Equatable, CaseIterable {
        case environment
        case headers
    }

    /// A value that holds a secret, and where it is.
    public struct Finding: Sendable, Equatable {
        public let field: Field
        public let key: String

        public init(field: Field, key: String) {
            self.field = field
            self.key = key
        }

        /// The one line every surface prints.
        ///
        /// The suggested name is derived from the key and marked as an example,
        /// because it is one: the variable a connector needs is usually not
        /// named after the header it travels in. `Authorization` gets
        /// `${AUTHORIZATION}`, which works and is almost never what the author
        /// meant — saying so is cheaper than a message that reads as a
        /// prescription and turns out to be a guess.
        public var rendered: String {
            let suggestion = CredentialReference.suggestedVariableName(for: key)
            return "`\(field.rawValue).\(key)` holds what looks like a literal credential"
                + " — name it instead, e.g. `\(CredentialSyntax.shell.render(suggestion))`, and"
                + " keep the value in the environment the agents run in; a value written"
                + " into four config files has four places to leak from and four places"
                + " to rotate"
        }
    }

    // The upstream constants, kept as they were read rather than tidied.

    /// Secrets that are recognisable whatever the key is called.
    static let knownShapes = [
        #"\bsk-[A-Za-z0-9_-]{16,}"#,
        #"\bgh[opsur]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{30,}"#,
        #"\bxox[abeprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bglpat-[A-Za-z0-9_-]{20,}"#,
        #"\bAIza[0-9A-Za-z_-]{35}\b"#,
        #"(?:^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+"#,
    ]

    /// A key that is asking to hold a credential.
    static let credentialKey = "authorization|api[-_]?key|token|secret|password|credential"
    /// Text that says a value was meant to be replaced.
    static let placeholder = #"your[-_ ]|replace|example|changeme|placeholder|dummy|redacted|xxx|[<>]|\*\*\*"#
    /// `Bearer x`, and the three schemes shaped like it.
    static let authScheme = #"^(?:Bearer|Basic|Token|Bot)\s+(\S+)$"#

    static let maximumLength = 8192
    static let minimumLength = 20
    static let minimumEntropy = 3.0

    /// Whether `value` holds a secret under `key`.
    public static func looksLikeLiteralCredential(key: String, value: String) -> Bool {
        // A value that names its secret is the answer, not the problem. Checked
        // first, and against every form this type accepts — see the note above.
        guard !CredentialReference.isReference(value) else { return false }
        guard value.count <= maximumLength else { return false }
        guard !matches(placeholder, value, caseInsensitive: true) else { return false }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if knownShapes.contains(where: { matches($0, trimmed, caseInsensitive: false) }) {
            return true
        }

        guard matches(credentialKey, key, caseInsensitive: true) else { return false }

        let candidate = schemePayload(trimmed) ?? trimmed
        return candidate.count >= minimumLength
            && !candidate.contains { $0.isWhitespace }
            && entropy(candidate) >= minimumEntropy
    }

    /// Every value in `values` that holds a secret.
    ///
    /// Sorted by field and key so two runs print the same list, which is what
    /// makes the refusal reproducible in a test.
    public static func findings(
        environment: [String: String],
        headers: [String: String]
    ) -> [Finding] {
        var found: [Finding] = []
        for field in Field.allCases {
            let pairs = field == .environment ? environment : headers
            for key in pairs.keys.sorted() {
                guard let value = pairs[key] else { continue }
                if looksLikeLiteralCredential(key: key, value: value) {
                    found.append(Finding(field: field, key: key))
                }
            }
        }
        return found
    }

    // MARK: - The pieces

    private static func matches(
        _ pattern: String,
        _ text: String,
        caseInsensitive: Bool
    ) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        ) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// The part after a `Bearer`/`Basic`/`Token`/`Bot` scheme, or `nil`.
    private static func schemePayload(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: authScheme, options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let payload = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[payload])
    }

    /// Shannon entropy, in bits per character.
    ///
    /// The measure the upstream rule uses. A key is drawn from a wide alphabet
    /// and scores above 3; an English word repeats letters and scores below it,
    /// which is what stops `authorization: Bearer administrator` being refused.
    static func entropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        var total = 0.0
        for count in counts.values {
            let share = Double(count) / Double(text.count)
            total -= share * log2(share)
        }
        return total
    }
}
