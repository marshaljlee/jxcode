import Foundation
import Security

/// The shared secret that guards `ModelRouter`.
///
/// The router holds the user's real API keys and forwards anything it is asked
/// to, so an unauthenticated router is an open proxy onto the user's billing
/// account: any process on the machine can POST to `127.0.0.1:5255` and spend
/// the user's credits. Binding to loopback keeps other machines out, but it does
/// nothing about the other processes running as the same user, which is the
/// threat this closes.
///
/// Auth is deliberately opt-in. Defaulting it on would mean an upgrade silently
/// breaks every already-configured agent, and a user who cannot reach their own
/// router will turn the feature off rather than fix it — so the safe default is
/// off, and the failure mode once enabled is closed rather than open.
public struct RouterAuth: Sendable, Equatable, Codable {

    public var isEnabled: Bool
    public var token: String?

    public init(isEnabled: Bool = false, token: String? = nil) {
        self.isEnabled = isEnabled
        self.token = token
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case token
    }

    /// Hand-written so a partial or wrong-typed file degrades to "disabled"
    /// instead of throwing. The synthesised decoder requires `isEnabled` to be
    /// present and correctly typed, which would turn a truncated write into a
    /// decode failure the caller has to reason about.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        token = try? container.decodeIfPresent(String.self, forKey: .token)
    }

    // MARK: - File location

    /// `state/router-auth.json`, alongside the other stores.
    ///
    /// Lives next to `providers.json` because it is the same class of secret:
    /// losing it or leaking it changes what the router will do for a caller.
    static func fileURL(in paths: SandboxPaths) -> URL {
        paths.state.appendingPathComponent("router-auth.json")
    }

    // MARK: - Tokens

    /// A fresh random token, URL-safe.
    ///
    /// Standard base64 is not usable here: `+` and `/` are meaningful in JSON
    /// only when escaped, `/` terminates a TOML key path, and both are shell
    /// metacharacters. A token containing them corrupts the agent config file it
    /// is pasted into, and the resulting bug looks like a router failure rather
    /// than an encoding one. base64url (`-` and `_`) is inert in JSON, YAML,
    /// TOML and a shell, so it is safe to round-trip through all of them. The
    /// `=` padding is dropped for the same reason: it needs quoting in several
    /// of those formats and carries no information.
    public static func generateToken(byteCount: Int = 32) -> String {
        // A zero or negative request would produce an empty token, and an empty
        // token is indistinguishable from "not configured" downstream.
        let count = max(1, byteCount)

        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Unreachable on macOS in practice. SystemRandomNumberGenerator is
            // also CSPRNG-backed, so falling back to it is safe; returning an
            // empty token would not be, since it would silently degrade into the
            // fail-closed path and look like a wrong password.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }

        var encoded = Data(bytes).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-")
        encoded = encoded.replacingOccurrences(of: "/", with: "_")
        encoded = encoded.replacingOccurrences(of: "=", with: "")
        return encoded
    }

    // MARK: - Verification

    /// Whether a request carrying these headers is authorised.
    ///
    /// Two schemes are accepted because agents disagree about which one to use,
    /// and a router that only understands one of them is broken for half its
    /// callers:
    ///
    ///   - `x-api-key: <token>` — Anthropic style, sent by Claude Code when
    ///     `ANTHROPIC_API_KEY` is set.
    ///   - `Authorization: Bearer <token>` — sent by Claude Code when
    ///     `ANTHROPIC_AUTH_TOKEN` is set, and by every OpenAI-shaped client.
    ///
    /// Header names and the `Bearer` scheme word are matched case-insensitively
    /// because HTTP field names are case-insensitive by definition and clients
    /// vary the scheme's capitalisation; rejecting a correct token over the
    /// spelling of `bearer` is a support burden with no security benefit.
    public func accepts(headers: [String: String]) -> Bool {
        // Opt-in: with auth off the router behaves exactly as it did before this
        // type existed.
        guard isEnabled else { return true }

        // Enabled with no usable token is a misconfiguration, not "off". It has
        // to fail closed: the user believes the router is protected, so allowing
        // every request through would be strictly worse than having no auth at
        // all, because it also removes the reason to notice the problem.
        guard let expected = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            return false
        }

        // Lowercase every incoming name once. `HTTPRequestParser` already folds
        // them, but `accepts` is public and must not depend on the caller having
        // normalised anything.
        var folded: [String: String] = [:]
        for (name, value) in headers where folded[name.lowercased()] == nil {
            folded[name.lowercased()] = value
        }

        if let presented = folded["x-api-key"],
           Self.constantTimeEquals(
               presented.trimmingCharacters(in: .whitespacesAndNewlines),
               expected
           ) {
            return true
        }

        if let raw = folded["authorization"],
           let presented = Self.bearerToken(in: raw),
           Self.constantTimeEquals(presented, expected) {
            return true
        }

        return false
    }

    /// The token part of an `Authorization` header, or nil if it is not a
    /// bearer scheme. Surrounding whitespace is tolerated because some clients
    /// pad the value and some proxies re-serialise it.
    private static func bearerToken(in value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = "bearer"
        guard trimmed.count > scheme.count else { return nil }
        guard trimmed.prefix(scheme.count).caseInsensitiveCompare(scheme) == .orderedSame else {
            return nil
        }

        let remainder = trimmed.dropFirst(scheme.count)
        // Require a separator, so a scheme such as `BearerX` is not misread as
        // the bearer scheme with a token of `X`.
        guard let separator = remainder.first, separator == " " || separator == "\t" else {
            return nil
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Byte-wise comparison that does not stop at the first difference.
    ///
    /// `String.==` returns as soon as it finds a mismatched byte, so the time it
    /// takes reveals how many leading bytes were correct. An attacker who can
    /// measure that can recover a token one byte at a time instead of guessing
    /// the whole thing. That matters here even though the router is loopback
    /// only: the threat model is *other processes on the same machine* — a
    /// compromised agent, a dependency's postinstall script, another user's
    /// session — and every one of them can issue unlimited requests and time
    /// them. Loopback is not a trust boundary.
    ///
    /// Both lengths are folded into the accumulator rather than compared up
    /// front, so a length mismatch is not a separate, faster path. The loop
    /// count still depends on the longer input, which leaks length; that is
    /// inherent to comparing variable-length strings, and a token of a fixed
    /// generated length makes it a constant anyway.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)

        var difference = UInt64(left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt64(a ^ b)
        }
        return difference == 0
    }

    // MARK: - Agent configuration

    /// The environment an agent needs so that it authenticates to the router.
    ///
    /// One definition, because the shapes have to agree. An earlier version of
    /// this existed while `Sandbox` hand-wrote two of the three keys into the
    /// process environment itself, so the two lists drifted: Anthropic-shaped
    /// agents got a token and OpenAI-shaped ones got nothing at all. With auth
    /// enabled that read as "routing is broken" — the router answered 401 to
    /// every agent that was not Claude Code, whichever backend was selected.
    ///
    ///   - `ANTHROPIC_AUTH_TOKEN` is the one that matters for Claude Code: it is
    ///     the documented lever for a gateway, and it makes the client send
    ///     `Authorization: Bearer`.
    ///   - `ANTHROPIC_API_KEY` is set to the *empty string* rather than omitted,
    ///     because Claude Code falls back to it when the auth token is absent
    ///     and would then send the user's real Anthropic key to the router —
    ///     which is exactly the credential this feature exists to keep out of
    ///     the sandbox.
    ///   - `OPENAI_API_KEY` covers OpenAI-shaped clients — Gemini, opencode,
    ///     oh-my-pi — which reach the router through `OPENAI_BASE_URL` alone
    ///     and otherwise send no credential at all.
    ///   - `JXCODE_API_KEY` is the name `AgentConfigWriter` declares as Codex's
    ///     `env_key` in `config.toml`. Codex reads the *named variable* rather
    ///     than a fixed one, so the name in the config and the name exported
    ///     here have to match; naming one and exporting the other silently
    ///     sends Codex unauthenticated.
    public var agentEnvironment: [String: String] {
        guard isEnabled,
              let token,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        return [
            "ANTHROPIC_AUTH_TOKEN": token,
            "ANTHROPIC_API_KEY": "",
            "OPENAI_API_KEY": token,
            "JXCODE_API_KEY": token,
        ]
    }

    // MARK: - Persistence

    /// Read the stored auth, or a disabled instance.
    ///
    /// Never throws. A missing file is the normal first-run state, and a corrupt
    /// one must not stop the app from starting: the user can then open the UI and
    /// regenerate the token, which is not possible if `load` traps or propagates.
    ///
    /// A file that is valid JSON but has `isEnabled` set with no token is
    /// returned as-is rather than silently rewritten to disabled. Disabling it
    /// would hand out access while the UI still claimed protection; leaving it
    /// enabled makes `accepts` fail closed, which is loud and fixable.
    public static func load(from paths: SandboxPaths) -> RouterAuth {
        guard let data = try? Data(contentsOf: fileURL(in: paths)), !data.isEmpty else {
            return RouterAuth()
        }
        guard let decoded = try? JSONDecoder().decode(RouterAuth.self, from: data) else {
            return RouterAuth()
        }
        return decoded
    }

    /// Persist the auth.
    ///
    /// The file is a bearer credential in plaintext, so it is written `0600` and
    /// its directory `0700`. The mode is applied *after* the atomic write
    /// because `Data.write(options: .atomic)` renames a fresh temporary file
    /// over the target, and that replacement carries the process umask's
    /// permissions rather than the target's — setting the mode on the target
    /// first would be undone by the rename.
    public func save(to paths: SandboxPaths) throws {
        let file = Self.fileURL(in: paths)
        let directory = file.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }
}
