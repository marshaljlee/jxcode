import Foundation

// MARK: - Aliases and profiles
//
// The problem, stated the way the user meets it: an agent's config names a
// model, and a model is a multi-gigabyte file at a path. Every time the file
// moves, or the user decides a different quantisation is the right trade this
// week, the agent's config has to be rewritten — and a rewrite is a bind, and a
// bind can fail on three of four agents for reasons that have nothing to do
// with the model.
//
// So the name in the config has to be stable and the binding has to be
// volatile. That is the whole design:
//
//   - an **alias** is the stable name — `coder`, `vision` — written once into
//     every agent's config and never touched again;
//   - a **profile** is the volatile binding: a named set of alias → file. The
//     active profile decides what `coder` means right now, and switching it is
//     one string in one file that no agent reads.
//
// There is already a field called `aliases` on `RouterConfiguration`, and it is
// a *different thing*: a list of names to intercept and collapse onto the one
// configured model. That is the right mechanism for making Claude Code's
// `claude-sonnet-4-5-20250929` land on your GGUF, and it is exactly wrong here,
// because every alias there resolves to the same model — so `vision` and
// `coder` cannot be two different files, which is the entire point of having
// two names.

/// A stable name an agent can ask for, and the file it means.
public struct ModelAlias: Codable, Identifiable, Hashable, Sendable {
    /// What the agent asks for. Compared case-insensitively, because a model
    /// name travels through a config file, a JSON body and an HTTP header
    /// before it gets here and nobody keeps its case straight across all three.
    public var name: String

    /// The GGUF file, as an absolute path.
    ///
    /// Stored rather than an id into the model library on purpose. The library
    /// is a scan of directories the user may reorder, and an alias that stops
    /// resolving because a scan root moved is a worse failure than a path that
    /// goes stale loudly — "no such file" names the file, a dangling id names
    /// nothing.
    public var modelPath: String

    /// Per-alias policy overrides. `nil` means "use whatever the caller asked
    /// for", which is what keeps a profile from freezing a global setting.
    public var memory: MemoryPolicy?
    public var cache: CachePolicy?
    public var sampling: SamplingPreset?

    /// Unload this one after this long idle, overriding the profile's value.
    ///
    /// Per-alias rather than per-profile only, because the reason to unload
    /// fast is a property of the model: a 16 GB model that takes a minute to
    /// load is worth holding; a 600 MB one is not worth an argument about.
    public var idleTimeout: TimeInterval?

    public var id: String { name.lowercased() }

    public init(
        name: String,
        modelPath: String,
        memory: MemoryPolicy? = nil,
        cache: CachePolicy? = nil,
        sampling: SamplingPreset? = nil,
        idleTimeout: TimeInterval? = nil
    ) {
        self.name = name
        self.modelPath = modelPath
        self.memory = memory
        self.cache = cache
        self.sampling = sampling
        self.idleTimeout = idleTimeout
    }
}

/// A named set of bindings. Swapping the active profile re-points every alias
/// at once, without writing a byte of agent config.
public struct ModelProfile: Codable, Identifiable, Hashable, Sendable {

    /// Fifteen minutes.
    ///
    /// Chosen against the cost on both sides. Loading a model off a spinning
    /// disk and onto the GPU takes tens of seconds, and the pause a person
    /// takes to read a diff and decide what to ask next is minutes — so a
    /// shorter TTL unloads the model during exactly the pause it exists to
    /// serve, and the user pays the load twice for one conversation. The other
    /// side is a machine that is holding gigabytes for a session the user
    /// walked away from, which fifteen minutes bounds without being cruel.
    public static let defaultIdleTimeout: TimeInterval = 900

    public var name: String
    public var aliases: [ModelAlias]
    public var idleTimeout: TimeInterval

    public var id: String { name }

    public init(
        name: String,
        aliases: [ModelAlias] = [],
        idleTimeout: TimeInterval = ModelProfile.defaultIdleTimeout
    ) {
        self.name = name
        self.aliases = aliases
        self.idleTimeout = idleTimeout
    }

    /// The alias called `name`, case-insensitively.
    ///
    /// When a profile somehow holds two entries that differ only in case — a
    /// hand-edited file, or an older version that did not fold them — the
    /// *first* wins rather than the last. Deterministic either way; first
    /// matches what the file reads like to a person.
    public func alias(named name: String) -> ModelAlias? {
        aliases.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public enum ModelLifecycleError: Error, LocalizedError, Equatable {
    case invalidName(String, what: String)
    case unknownProfile(String, known: [String])
    // No `unknownAlias` here. There used to be, with a written message, and
    // nothing ever threw it: `removeAlias(named:)` returns `false` for a name
    // that was not there, which is the right ergonomics for an unbind and
    // cannot be both. The case that *does* fire is `ModelServingError
    // .unknownAlias` in `ModelSupervisor.swift`, and it carries the list of
    // names that would have worked — strictly more useful than the copy here.
    case duplicateProfile(String)
    case lastProfile(String)
    case invalidIdleTimeout(TimeInterval)
    case missingModel(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name, let what):
            return "'\(name)' is not a usable \(what) name. Use letters, digits, "
                + "dots, dashes and underscores — no spaces, no slashes, no colons: "
                + "this string travels in an agent's config and in a JSON body."
        case .unknownProfile(let name, let known):
            // The ternary is concatenated rather than interpolated: a string
            // literal nested inside an interpolation nested inside the literal
            // it is interpolating does not parse, and the compiler's complaint
            // ("unterminated string literal") names the outer string rather
            // than the nesting that caused it.
            return "no profile named '\(name)'. " + (known.isEmpty
                ? "There are no profiles at all."
                : "Known: \(known.joined(separator: ", ")).")
        case .duplicateProfile(let name):
            return "a profile named '\(name)' already exists"
        case .lastProfile(let name):
            return "'\(name)' is the only profile. Removing it would leave the "
                + "router with nowhere to resolve an alias; add another first."
        case .invalidIdleTimeout(let seconds):
            return "\(Int(seconds))s is not a usable idle timeout. Use 0 to keep a "
                + "model loaded until it is stopped by hand, or a positive number "
                + "of seconds."
        case .missingModel(let url):
            return "no file at \(url.path). An alias is only worth binding to a "
                + "model that is on disk — the failure is otherwise a load error "
                + "minutes later that names the path, not the alias."
        }
    }
}

/// The alias table and the lifecycle policy, in one file.
///
/// One file, one owner — the same shape as `AgentRegistry`, `ToolRegistry` and
/// `ProviderStore`, and for the same reason: two files that have to agree is
/// two files that can disagree, and the disagreement shows up as an alias that
/// resolves in the terminal and not in the window.
public final class ModelLifecycleStore {

    /// The profile name used when there is no file yet.
    public static let defaultProfileName = "default"

    public private(set) var profiles: [ModelProfile]
    public private(set) var activeProfileName: String

    private let fileURL: URL

    public init(paths: SandboxPaths = .default) {
        self.fileURL = paths.modelsFile
        self.profiles = [ModelProfile(name: Self.defaultProfileName)]
        self.activeProfileName = Self.defaultProfileName
        load()
    }

    /// A store backed by an explicit file, for tests.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.profiles = [ModelProfile(name: Self.defaultProfileName)]
        self.activeProfileName = Self.defaultProfileName
        load()
    }

    public var file: URL { fileURL }

    // MARK: Reading

    /// The profile that is currently deciding what every alias means.
    ///
    /// Never `nil` and never empty. A store whose file names a profile that is
    /// not in it falls back to the first one rather than to nothing: an alias
    /// table that silently resolves to nothing looks identical to a table with
    /// no aliases, and only one of those is a mistake.
    public var activeProfile: ModelProfile {
        profiles.first { $0.name == activeProfileName } ?? profiles[0]
    }

    public func profile(named name: String) -> ModelProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func alias(named name: String) -> ModelAlias? {
        activeProfile.alias(named: name)
    }

    public var knownAliases: [String] { activeProfile.aliases.map(\.name) }

    public var knownProfileNames: [String] { profiles.map(\.name) }

    // MARK: Writing

    public func setAlias(_ alias: ModelAlias) throws {
        try Self.validate(alias.name, what: "alias")
        guard alias.idleTimeout.map({ $0 >= 0 }) ?? true else {
            throw ModelLifecycleError.invalidIdleTimeout(alias.idleTimeout ?? 0)
        }

        // The check `ModelLifecycleError.missingModel` was written for and,
        // until now, was never thrown by — a case whose message argues a policy
        // the code did not implement. The argument is the message's own: an
        // alias bound to a path with nothing behind it fails minutes later, at
        // load time, naming the path, which is the one thing the alias exists
        // to stop mattering. Refusing here names the alias instead.
        //
        // A directory is accepted, because that is what `jxcode serve` and
        // `LlamaServerSupervisor.localModel(at:)` both accept — the scanner
        // resolves a model by scanning its containing directory.
        //
        // The path is stored expanded and standardised rather than as typed.
        // `~` is expanded by a shell and by nothing else, and this string is
        // about to be read by an agent's config loader and a JSON decoder.
        var alias = alias
        let target = URL(fileURLWithPath: (alias.modelPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ModelLifecycleError.missingModel(target)
        }
        alias.modelPath = target.path

        var profile = activeProfile
        // Upsert on the folded name, so `Coder` replaces `coder` rather than
        // sitting beside it. Two entries that differ only in case would make
        // "which model does `coder` get" depend on scan order.
        profile.aliases.removeAll { $0.id == alias.id }
        profile.aliases.append(alias)
        profile.aliases.sort { $0.name.lowercased() < $1.name.lowercased() }
        try replace(profile)
    }

    @discardableResult
    public func removeAlias(named name: String) throws -> Bool {
        var profile = activeProfile
        let before = profile.aliases.count
        profile.aliases.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard profile.aliases.count != before else { return false }
        try replace(profile)
        return true
    }

    public func setIdleTimeout(_ seconds: TimeInterval, profile name: String? = nil) throws {
        guard seconds >= 0 else { throw ModelLifecycleError.invalidIdleTimeout(seconds) }

        let target = name ?? activeProfile.name
        guard var profile = profile(named: target) else {
            throw ModelLifecycleError.unknownProfile(target, known: knownProfileNames)
        }
        profile.idleTimeout = seconds
        try replace(profile)
    }

    public func addProfile(named name: String, idleTimeout: TimeInterval = ModelProfile.defaultIdleTimeout) throws {
        try Self.validate(name, what: "profile")
        guard profile(named: name) == nil else {
            throw ModelLifecycleError.duplicateProfile(name)
        }
        guard idleTimeout >= 0 else { throw ModelLifecycleError.invalidIdleTimeout(idleTimeout) }
        profiles.append(ModelProfile(name: name, idleTimeout: idleTimeout))
        try save()
    }

    public func selectProfile(named name: String) throws {
        guard profile(named: name) != nil else {
            throw ModelLifecycleError.unknownProfile(name, known: knownProfileNames)
        }
        activeProfileName = profile(named: name)?.name ?? name
        try save()
    }

    public func removeProfile(named name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw ModelLifecycleError.unknownProfile(name, known: knownProfileNames) }

        guard profiles.count > 1 else { throw ModelLifecycleError.lastProfile(profiles[index].name) }

        let removed = profiles.remove(at: index)
        if activeProfileName == removed.name { activeProfileName = profiles[0].name }
        try save()
    }

    /// Replace the copy of `profile` that is already in the list, by name.
    ///
    /// By *name* rather than by index because every caller above built its
    /// profile from `activeProfile`, which is a value copy — and an index
    /// captured before an edit is the kind of thing that survives a refactor
    /// and then points at the wrong profile.
    private func replace(_ profile: ModelProfile) throws {
        guard let index = profiles.firstIndex(where: { $0.name == profile.name }) else {
            throw ModelLifecycleError.unknownProfile(profile.name, known: knownProfileNames)
        }
        profiles[index] = profile
        try save()
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var activeProfile: String
        var profiles: [ModelProfile]
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.profiles.isEmpty else { return }

        profiles = stored.profiles
        // An active profile that is not in the list is repaired here rather
        // than tolerated at every read site.
        activeProfileName = stored.profiles.contains { $0.name == stored.activeProfile }
            ? stored.activeProfile
            : stored.profiles[0].name
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Stored(activeProfile: activeProfileName, profiles: profiles))
        try data.write(to: fileURL, options: .atomic)
    }

    /// A name that survives a config file, a JSON body and a URL path.
    ///
    /// The allowlist is the point. `coder/2` and `coder:2` both look fine in a
    /// shell and both mean something else in the three places this string is
    /// about to be written, so they are refused at the moment they are typed
    /// rather than at the moment an agent cannot find its model.
    static func validate(_ name: String, what: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !name.isEmpty,
              name.count <= 64,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ModelLifecycleError.invalidName(name, what: what)
        }
    }
}

// MARK: - The four log streams
//
// llama-swap splits its output four ways and the split is the useful half of
// the idea, not the binary. One mixed stream cannot answer the question people
// actually have — "what did *this* model say when it failed to load" — because
// the answer is buried under three other servers' token-by-token chatter and
// the router's own decisions.
//
// The four, and why each is separate from the others:
//
//   - **proxy** — what the router decided and where it sent it. The file the
//     router's `RouterLog` already writes.
//   - **http** — one line per request the router accepted, before any decision
//     is made. Separate from proxy because "the agent never sent anything" and
//     "the agent sent something the router refused" are the same shape in a
//     decision log and opposite diagnoses.
//   - **upstream** — every llama-server's own stdout and stderr, interleaved in
//     start order. Separate from per-model because the interesting failures are
//     often *ordering*: a second model loading while the first is still
//     unloading is a Metal allocation failure that no single model's log
//     explains.
//   - **model** — one server's own output, on its own. This is the file to read
//     when one model fails to load and three others are serving traffic.

public enum ModelLogStream: String, CaseIterable, Identifiable, Sendable {
    case proxy
    case http
    case upstream
    case model

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .proxy:    return "proxy"
        case .http:     return "http"
        case .upstream: return "upstream"
        case .model:    return "model"
        }
    }

    /// What this stream is for, in the words the pane shows.
    public var purpose: String {
        switch self {
        case .proxy:
            return "what the router decided — routing, translation notes, refusals"
        case .http:
            return "every request the router accepted, before it decided anything"
        case .upstream:
            return "every llama-server's own output, in start order"
        case .model:
            return "one model's own output, with nothing else mixed in"
        }
    }

    /// Whether this stream is per-model. `model` is the only one that is, and
    /// asking for it without an alias is a caller mistake worth reporting
    /// rather than a path to invent.
    public var isPerModel: Bool { self == .model }
}

public struct ModelLogs: Sendable {

    public let paths: SandboxPaths

    public init(paths: SandboxPaths) {
        self.paths = paths
    }

    /// Where a stream's bytes go.
    ///
    /// `alias` is required for `.model` and ignored for the other three, which
    /// are shared. Returning `nil` rather than a placeholder path is what stops
    /// a per-model read from silently returning the shared file.
    public func fileURL(_ stream: ModelLogStream, alias: String? = nil) -> URL? {
        switch stream {
        case .proxy:    return paths.logs.appendingPathComponent("router.log")
        case .http:     return paths.logs.appendingPathComponent("http.log")
        case .upstream: return paths.logs.appendingPathComponent("upstream.log")
        case .model:
            guard let alias, !alias.isEmpty else { return nil }
            return paths.modelLogs.appendingPathComponent("\(Self.slug(alias)).log")
        }
    }

    /// A filename-safe form of an alias.
    ///
    /// Aliases are already validated to `[A-Za-z0-9._-]`, so this is defence
    /// against an older or hand-edited file rather than against the writer.
    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let folded = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(folded)
        return slug.isEmpty ? "unnamed" : slug
    }

    /// The last few kilobytes of a stream, whole lines only.
    ///
    /// Read from the end: llama-server logs a line per token in verbose mode,
    /// and a session's log is not something to load into memory to show the
    /// last twenty lines. Same technique as `LlamaServer.logTail`, deliberately
    /// — two tails that disagree about where a line begins is a bug nobody
    /// finds twice.
    public func tail(
        _ stream: ModelLogStream,
        alias: String? = nil,
        maxBytes: Int = 16_384
    ) -> String {
        guard let url = fileURL(stream, alias: alias) else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return "" }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }

        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    /// Create the directory a stream's file lives in, and touch the file.
    ///
    /// Called before a server starts rather than at first write, so a pane that
    /// opens the stream before anything has been logged shows an empty file
    /// instead of an error about a missing one.
    @discardableResult
    public func prepare(_ stream: ModelLogStream, alias: String? = nil) -> URL? {
        guard let url = fileURL(stream, alias: alias) else { return nil }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}

// MARK: - One stream, several files
//
// A model's own output is wanted in two places at once, which is half of why
// llama-swap splits its logs four ways. The per-model file answers "what did
// *this* model say when it failed to load"; the upstream file answers the
// question no single model's log can — whether a second model started while the
// first was still unloading, which is a Metal allocation failure that neither
// file explains on its own.
//
// `Process` takes exactly one `standardOutput`, so the fan-out has to happen on
// this side of a pipe. That is a real trade and worth naming: the child no
// longer writes straight into the file, so a parent that dies closes the pipe
// and the child dies with it. That is the better failure here — an orphaned
// `llama-server` holding several gigabytes is the thing this app exists to
// prevent, and a log line lost to a dying parent is cheaper than that.
//
// Until this existed, `logs/upstream.log` was created by `ModelLogs.prepare`
// and never written to by anything, so `jxcode local logs upstream` and the
// pane both showed an empty file under a heading that promised every server's
// output. An empty file that means "nothing happened" and an empty file that
// means "nobody ever writes here" look identical, and only one of them is true.

public final class LogTee: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [FileHandle] = []

    /// Open every URL for appending, creating what is missing.
    ///
    /// A URL that cannot be opened is skipped rather than fatal: losing the
    /// shared upstream file should not stop a model from loading, and the
    /// per-model file is the one a failure needs.
    public init(urls: [URL]) {
        for url in urls {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { continue }
            // Append rather than truncate, for the same reason `LlamaServer`
            // appends: a restart should not erase the run that explains why the
            // restart happened.
            _ = try? handle.seekToEnd()
            handles.append(handle)
        }
    }

    /// Whether anything is being written at all. `false` means the caller has
    /// nowhere to put the child's output, which is worth refusing over.
    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !handles.isEmpty
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for handle in handles { try? handle.write(contentsOf: data) }
    }

    public func close() {
        lock.lock()
        let open = handles
        handles = []
        lock.unlock()
        for handle in open { try? handle.close() }
    }
}
