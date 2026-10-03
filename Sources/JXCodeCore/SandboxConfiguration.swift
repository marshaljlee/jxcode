import Foundation

/// The parts of the sandbox's environment policy the user owns.
///
/// `SandboxOptions` also carries the router URL and its token, and those are
/// runtime facts rather than settings: they are derived from whether routing is
/// on, and a file that could set them would be a second, silently-winning
/// answer to a question `RoutingActivation` already answers. So only the three
/// editable fields live here, and `options(routerURL:routerToken:)` puts them
/// back together with whatever routing decided.
///
/// Everything in this type is a lever on the isolation boundary, which is why
/// validation is not optional and why the reserved lists below exist. See
/// `validate(env:pathEntries:)`.
public struct SandboxConfiguration: Codable, Equatable, Sendable {

    public var includeHostLocalBin: Bool
    public var extraPathEntries: [String]
    public var extraEnv: [String: String]

    public init(
        includeHostLocalBin: Bool = false,
        extraPathEntries: [String] = [],
        extraEnv: [String: String] = [:]
    ) {
        self.includeHostLocalBin = includeHostLocalBin
        self.extraPathEntries = extraPathEntries
        self.extraEnv = extraEnv
    }

    public static let `default` = SandboxConfiguration()

    /// Recombine the editable fields with the runtime ones.
    public func options(routerURL: String? = nil, routerToken: String? = nil) -> SandboxOptions {
        SandboxOptions(
            includeHostLocalBin: includeHostLocalBin,
            extraPathEntries: extraPathEntries,
            extraEnv: extraEnv,
            routerURL: routerURL,
            routerToken: routerToken
        )
    }

    // MARK: - What a user may not change

    /// Variables the sandbox sets itself, because they *are* the sandbox.
    ///
    /// `HOME` is the load-bearing one: an extra environment variable is applied
    /// after everything else and therefore wins, so `HOME=/Users/you` here would
    /// hand every agent the real home directory and quietly undo the one
    /// mechanism the whole app is built on. The rest are the same argument at
    /// smaller scale — `XDG_*` and the per-agent config roots decide where an
    /// agent reads and writes, and the `*_BASE_URL` / key variables decide
    /// whether it talks to the router or straight out to a provider.
    ///
    /// Refused rather than warned about: a warning on a screen nobody re-reads
    /// is not a guardrail.
    public static let reservedKeys: Set<String> = [
        "HOME",
        "PATH",
        "TMPDIR",
        "ZDOTDIR",
        "SHELL",
        "USER",
        "LOGNAME",
        "CLAUDE_CONFIG_DIR",
        "CODEX_HOME",
        "GEMINI_CONFIG_DIR",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "npm_config_prefix",
        "NPM_CONFIG_PREFIX",
        "HOMEBREW_PREFIX",
        "HOMEBREW_CELLAR",
        "HOMEBREW_REPOSITORY",
        "HOMEBREW_CACHE",
        "ANTHROPIC_BASE_URL",
        "OPENAI_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "OPENAI_API_KEY",
        "JXCODE_ROOT",
        "JXCODE_ROUTER_URL",
    ]

    /// Directories that are host-wide tool locations, and therefore the thing
    /// the sandbox exists to keep out.
    ///
    /// An "extra path" pointing at one of these would be a second door into the
    /// same room: `includeHostLocalBin` exists so that admitting
    /// `/usr/local/bin` is a visible, deliberate toggle, and letting the same
    /// directory in through the extra-entries list would make that toggle a
    /// decoration. `/opt/homebrew` is not available through any toggle, so it is
    /// refused outright.
    public static let deniedPathPrefixes: [String] = [
        "/opt/homebrew",
        "/usr/local",
    ]

    // MARK: - Validation

    /// `CustomStringConvertible` as well as `LocalizedError`, and it is not
    /// redundant: the CLI prints `"\(error)"`, which for an enum with
    /// associated values is `reservedKey("HOME")` rather than the sentence.
    /// `LocalizedError` alone would only be read by code that asks for
    /// `errorDescription` on purpose.
    public enum ValidationError: Error, LocalizedError, CustomStringConvertible, Equatable {
        case emptyKey
        case malformedKey(String)
        case reservedKey(String)
        case emptyValue(String)
        case notAbsolute(String)
        case deniedPath(String)

        public var errorDescription: String? {
            switch self {
            case .emptyKey:
                return "A variable name cannot be empty."
            case .malformedKey(let key):
                return "“\(key)” is not a usable variable name — letters, digits and underscores only, "
                    + "and it cannot contain “=”."
            case .reservedKey(let key):
                return "\(key) is set by the sandbox itself. Changing it would move the sandbox "
                    + "boundary rather than configure it."
            case .emptyValue(let key):
                return "\(key) cannot be set to an empty value. Unset it instead."
            case .notAbsolute(let entry):
                return "“\(entry)” is not an absolute path."
            case .deniedPath(let entry):
                return "“\(entry)” is a host-wide tool directory. Adding it would put Mac-installed "
                    + "tools inside the sandbox, which is what the sandbox is for."
            }
        }

        public var description: String { errorDescription ?? "\(self)" }
    }

    /// Reject anything that would move the isolation boundary instead of tuning it.
    ///
    /// Throws on the first problem rather than collecting them: the caller is a
    /// form or a CLI command that has to say one sentence, and "which one first"
    /// matters less than saying it plainly.
    public static func validate(key: String, value: String) throws {
        guard !key.isEmpty else { throw ValidationError.emptyKey }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard key.unicodeScalars.allSatisfy({ allowed.contains($0) }), !key.hasPrefix("=") else {
            throw ValidationError.malformedKey(key)
        }
        guard !reservedKeys.contains(key) else { throw ValidationError.reservedKey(key) }
        guard !value.isEmpty else { throw ValidationError.emptyValue(key) }
    }

    public static func validate(pathEntry: String) throws {
        let trimmed = pathEntry.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { throw ValidationError.notAbsolute(pathEntry) }
        let standardised = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        for denied in deniedPathPrefixes
        where standardised == denied || standardised.hasPrefix(denied + "/") {
            throw ValidationError.deniedPath(trimmed)
        }
    }

    /// A human-readable summary of what the user has asked for.
    ///
    /// Deliberately separate from `SandboxEnvironment.report`, which prints the
    /// environment these settings *produce*. Both are needed: one answers "what
    /// did I ask for", the other "what did I get", and the interesting failures
    /// live in the gap between them.
    public func report() -> String {
        var lines = ["Sandbox environment settings", ""]

        if extraEnv.isEmpty {
            lines.append("  variables: none")
        } else {
            lines.append("  variables:")
            for key in extraEnv.keys.sorted() {
                lines.append("    \(key)=\(extraEnv[key] ?? "")")
            }
        }

        if extraPathEntries.isEmpty {
            lines.append("  extra PATH entries: none")
        } else {
            lines.append("  extra PATH entries, highest priority first:")
            for entry in extraPathEntries { lines.append("    \(entry)") }
        }

        lines.append("  /usr/local/bin: \(includeHostLocalBin ? "included" : "excluded")")
        return lines.joined(separator: "\n")
    }

    /// The whole configuration, checked at once.
    public func validate() throws {
        for (key, value) in extraEnv {
            try Self.validate(key: key, value: value)
        }
        for entry in extraPathEntries {
            try Self.validate(pathEntry: entry)
        }
    }
}

// MARK: - The user's sandbox settings, on disk

/// Reads and writes `sandbox.json`.
///
/// Deliberately the same shape as `AgentRegistry` and `ToolRegistry`: one file,
/// one owner, loaded once and handed to whoever needs it. The alternative — each
/// caller reading the file for itself — is how the app and the CLI end up
/// disagreeing about which environment they are describing.
public final class SandboxConfigurationStore {

    private let paths: SandboxPaths

    /// The configuration as last read or written.
    public private(set) var configuration: SandboxConfiguration

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
        self.configuration = Self.load(from: paths)
    }

    public static func load(from paths: SandboxPaths) -> SandboxConfiguration {
        guard let data = try? Data(contentsOf: paths.sandboxConfigurationFile),
              let decoded = try? JSONDecoder().decode(SandboxConfiguration.self, from: data)
        else { return .default }
        // A file that no longer validates is not applied. It was written by an
        // older build with different rules, and honouring it would mean the
        // guardrails only hold for files written after the guardrails existed.
        return (try? decoded.validate()) == nil ? .default : decoded
    }

    public func save() throws {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: paths.sandboxConfigurationFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(configuration).write(to: paths.sandboxConfigurationFile, options: .atomic)
    }

    // MARK: - Mutation

    public func set(key: String, value: String) throws {
        try SandboxConfiguration.validate(key: key, value: value)
        configuration.extraEnv[key] = value
        try save()
    }

    /// Remove a variable. Reports whether there was one, so a caller can say
    /// "nothing to unset" instead of implying it did something.
    @discardableResult
    public func unset(key: String) throws -> Bool {
        guard configuration.extraEnv.removeValue(forKey: key) != nil else { return false }
        try save()
        return true
    }

    public func addPathEntry(_ entry: String) throws {
        try SandboxConfiguration.validate(pathEntry: entry)
        let standardised = URL(fileURLWithPath: entry).standardizedFileURL.path
        guard !configuration.extraPathEntries.contains(standardised) else { return }
        configuration.extraPathEntries.insert(standardised, at: 0)
        try save()
    }

    @discardableResult
    public func removePathEntry(_ entry: String) throws -> Bool {
        let standardised = URL(fileURLWithPath: entry).standardizedFileURL.path
        guard let index = configuration.extraPathEntries.firstIndex(of: standardised) else {
            return false
        }
        configuration.extraPathEntries.remove(at: index)
        try save()
        return true
    }

    public func setIncludeHostLocalBin(_ enabled: Bool) throws {
        configuration.includeHostLocalBin = enabled
        try save()
    }

    public func reset() throws {
        configuration = .default
        try save()
    }
}
