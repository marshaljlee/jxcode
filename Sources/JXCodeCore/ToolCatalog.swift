import Foundation

/// A command-line tool the dashboard can launch.
///
/// Tools are not agents. An agent is something JXCode *isolates* — it gets its
/// own `$HOME`, its own config, and a rebuilt `PATH`, because the point is to
/// stop it writing to the machine. A tool is something the user already runs,
/// and wants a button for. Keeping them as separate types rather than one type
/// with a flag means neither can drift into the other's behaviour: there is no
/// way to express "this tool should also be bound into five agents' configs",
/// because that is not a thing a tool does.
public struct ToolDefinition: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public let name: String
    /// The executable looked up on `PATH`.
    public let binary: String
    /// Passed on launch. Empty for a tool that opens its own interface.
    public let arguments: [String]
    /// One line for the card, in the same voice as an agent's tagline.
    public let tagline: String
    /// How to get it, when it is not on the machine yet. Shown on the card
    /// rather than run: a tool is something the user already chose to have, so
    /// the card's job is to say how to make it reachable, not to install things
    /// behind their back.
    ///
    /// Unlike an agent's, this may be a *host* installer — `hermes` and
    /// `cursor-agent` both install through a `curl | bash` one-liner that writes
    /// wherever it likes. That is allowed here and forbidden in `AgentCatalog`
    /// for a reason worth keeping straight: an agent is installed *into the
    /// sandbox*, so an installer that ignores `npm_config_prefix` would escape
    /// it. A tool is never installed by JXCode at all — the card is a note to
    /// the user, and the tool is then reached by linking what already exists.
    public let installCommand: String?
    /// Whether this came from the catalog or from the user. Written by
    /// `ToolRegistry.add`, and forced there rather than taken from the caller —
    /// `saveCustom()` persists only the entries that are not built in, so an
    /// entry that claimed to be built in would be dropped on the next write and
    /// the tool would vanish on relaunch.
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        binary: String,
        arguments: [String] = [],
        tagline: String,
        installCommand: String? = nil,
        isBuiltIn: Bool = true
    ) {
        self.id = id
        self.name = name
        self.binary = binary
        self.arguments = arguments
        self.tagline = tagline
        self.installCommand = installCommand
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, binary, arguments, tagline, installCommand, isBuiltIn
    }

    /// Hand-written so the two fields that arrived later degrade instead of
    /// throwing.
    ///
    /// The synthesised decoder requires every non-optional key to be present,
    /// which turns a `tools.json` written before `installCommand` existed into a
    /// decode failure — and a decode failure here is a user's tool list
    /// disappearing with no explanation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        binary = try container.decode(String.self, forKey: .binary)
        arguments = (try? container.decode([String].self, forKey: .arguments)) ?? []
        tagline = (try? container.decode(String.self, forKey: .tagline)) ?? ""
        installCommand = try? container.decodeIfPresent(String.self, forKey: .installCommand)
        isBuiltIn = (try? container.decode(Bool.self, forKey: .isBuiltIn)) ?? false
    }
}

/// The tools JXCode knows about out of the box.
///
/// Deliberately short and hand-written rather than discovered: a tool only
/// belongs here once someone has decided what its binary is called and how it
/// should be started. Discovery would put every executable on the machine in
/// the list, which is a `PATH` dump, not a dashboard.
public enum ToolCatalog {

    public static let builtIns: [ToolDefinition] = [
        ToolDefinition(
            id: "shell",
            name: "Plain shell",
            binary: "zsh",
            arguments: ["-l"],
            tagline: "Login zsh inside the sandbox, with no agent in front of it"
        ),
        ToolDefinition(
            id: "herdr",
            name: "herdr",
            binary: "herdr",
            tagline: "Terminal workspace manager for AI coding agents"
        ),
        ToolDefinition(
            id: "jcode",
            name: "jcode",
            binary: "jcode",
            tagline: "Coding agent on a Claude Max or ChatGPT Pro plan"
        )
    ]

    /// Tools worth offering, without putting them on the dashboard unasked.
    ///
    /// The built-in list is short on purpose — a dashboard that ships with
    /// fifteen cards for things the user does not have is a dashboard nobody
    /// reads. But the *list* being short was also the only thing standing
    /// between the user and a tool they run every day, because there was no way
    /// to add one at all. This is the middle: a catalog the Add-tool sheet
    /// offers, one click each, and a manual form for anything not here.
    ///
    /// Every binary here is a bare name, for the same reason the built-ins are:
    /// a name containing a slash is resolved as a *path* and would bypass the
    /// sandbox `PATH` search the locator is built on.
    public static let discoverable: [ToolDefinition] = [
        ToolDefinition(
            id: "hermes",
            name: "Hermes",
            binary: "hermes",
            tagline: "Agent stack with its own desktop app, ACP bridge and gateway",
            installCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
        ),
        ToolDefinition(
            id: "aider",
            name: "Aider",
            binary: "aider",
            tagline: "Pair-programming in the terminal, git-aware",
            installCommand: "python3 -m pip install aider-install && aider-install"
        ),
        ToolDefinition(
            id: "goose",
            name: "Goose",
            binary: "goose",
            tagline: "Block's extensible local coding agent",
            installCommand: "brew install block-goose-cli"
        ),
        ToolDefinition(
            id: "crush",
            name: "Crush",
            binary: "crush",
            tagline: "Charm's terminal coding agent",
            installCommand: "npm i -g @charmland/crush"
        ),
        ToolDefinition(
            id: "amp",
            name: "Amp",
            binary: "amp",
            tagline: "Sourcegraph's coding agent",
            installCommand: "npm i -g @sourcegraph/amp"
        ),
        ToolDefinition(
            id: "cursor-agent",
            name: "Cursor Agent",
            binary: "cursor-agent",
            tagline: "Cursor's command-line agent",
            installCommand: "curl https://cursor.com/install -fsS | bash"
        ),
        ToolDefinition(
            id: "qwen",
            name: "Qwen Code",
            binary: "qwen",
            tagline: "Alibaba's Qwen coding agent",
            installCommand: "npm i -g @qwen-code/qwen-code"
        )
    ]

    /// Everything the dashboard can offer: the built-ins, then anything the
    /// user added.
    ///
    /// Returns definitions only — it does not read `tools.json`. `ToolRegistry`
    /// is what owns the persisted list, and having two things that could answer
    /// "what are the tools" is exactly the drift this avoids.
    public static var all: [ToolDefinition] { builtIns }

    /// The catalog entries the dashboard is not already showing.
    ///
    /// Filtered on id, not on the binary, so a user who added their own `hermes`
    /// entry does not get offered a second one.
    public static func suggestions(absentFrom current: [ToolDefinition]) -> [ToolDefinition] {
        let taken = Set(current.map(\.id))
        return discoverable.filter { !taken.contains($0.id) }
    }
}

// MARK: - The user's tool list

/// The dashboard's tools: the built-ins plus whatever the user added.
///
/// Deliberately a mirror of `AgentRegistry`, down to the file-per-store shape
/// and the "force `isBuiltIn` to false on add" rule. The two differ in what
/// they *do* with an entry — an agent is launched inside the sandbox, a tool is
/// linked into it — and in nothing else, which is why the code is this similar.
public final class ToolRegistry {

    public private(set) var tools: [ToolDefinition]
    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
        self.tools = ToolCatalog.builtIns
        loadCustom()
    }

    // MARK: - Persistence

    private func loadCustom() {
        guard let data = try? Data(contentsOf: paths.toolsFile), !data.isEmpty,
              let custom = try? JSONDecoder().decode([ToolDefinition].self, from: data)
        else { return }
        // A custom entry overrides a built-in with the same id, so a user can
        // correct a tagline or point a built-in at a different binary without
        // waiting for a release.
        for tool in custom {
            if let index = tools.firstIndex(where: { $0.id == tool.id }) {
                tools[index] = tool
            } else {
                tools.append(tool)
            }
        }
    }

    public func saveCustom() throws {
        try FileManager.default.createDirectory(
            at: paths.state,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let custom = tools.filter { !$0.isBuiltIn }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(custom).write(to: paths.toolsFile, options: .atomic)
    }

    /// Add a tool, replacing any entry with the same id.
    public func add(_ tool: ToolDefinition) throws {
        var tool = tool
        tool.isBuiltIn = false
        tools.removeAll { $0.id == tool.id }
        tools.append(tool)
        try saveCustom()
    }

    /// Forget a tool the user added.
    ///
    /// Refuses a built-in rather than shadowing it: deleting a built-in from
    /// `tools.json` would leave it in `ToolCatalog.builtIns` and it would come
    /// straight back on the next launch, which reads as the delete having
    /// silently failed.
    @discardableResult
    public func remove(id: String) throws -> Bool {
        guard tools.contains(where: { $0.id == id && !$0.isBuiltIn }) else { return false }
        tools.removeAll { $0.id == id }
        try saveCustom()
        return true
    }

    public func isCustom(id: String) -> Bool {
        tools.contains { $0.id == id && !$0.isBuiltIn }
    }

    /// A stable, filesystem- and JSON-safe id derived from the display name.
    public static func slug(for name: String) -> String {
        Identifier.slug(name, fallback: "tool")
    }
}

/// Where a tool is, if it is anywhere.
public enum ToolLocator {

    /// Two places, and the difference is the whole point.
    public enum Location: Hashable, Sendable {
        /// Resolvable on the sandbox `PATH` — launchable as it stands.
        case sandbox(String)
        /// Installed on the Mac, but outside the sandbox. Usable by the user in
        /// their own shell, and *not* visible to an agent.
        case host(String)

        public var path: String {
            switch self {
            case .sandbox(let path), .host(let path): return path
            }
        }

        public var isInSandbox: Bool {
            if case .sandbox = self { return true }
            return false
        }
    }

    /// Directories searched for a host install, in priority order.
    ///
    /// Spelled out rather than read from the app's own `PATH`, which is the
    /// trap here: a GUI app launched from Finder inherits a minimal `PATH` that
    /// omits every one of these, so consulting `PATH` would report "not
    /// installed" for a tool the user runs every day. The sandbox lookup does
    /// the opposite and reads the *sandbox* `PATH` — the two are deliberately
    /// different sources, because they answer different questions.
    public static func hostSearchDirectories(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".cargo/bin", isDirectory: true),
            home.appendingPathComponent("bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true)
        ]
    }

    /// Find a tool, preferring the sandbox.
    ///
    /// Sandbox first, because that is the copy an agent would run and therefore
    /// the one that matters; a host install is reported only when the sandbox
    /// has none, which is the case the UI has to offer to fix.
    public static func locate(
        _ tool: ToolDefinition,
        environment: [String: String],
        hostHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Location? {
        if let inSandbox = ExecutableResolver.resolve(tool.binary, environment: environment) {
            return .sandbox(inSandbox)
        }
        for directory in hostSearchDirectories(home: hostHome) {
            let candidate = directory.appendingPathComponent(tool.binary)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return .host(candidate.path)
            }
        }
        return nil
    }
}

/// Making a host tool usable inside the sandbox.
public enum ToolLinker {

    /// Link a tool installed on the Mac into the sandbox's shared bin.
    ///
    /// A symlink rather than a copy, for the same reason `shared/bin` exists at
    /// all: it is one entry on the `PATH` that every agent resolves against, so
    /// linking once makes the tool available to all of them — and a link follows
    /// the original when the tool updates itself, where a copy would go stale
    /// the first time it did.
    ///
    /// Returns the path of the link.
    @discardableResult
    public static func link(
        tool: ToolDefinition,
        from source: String,
        paths: SandboxPaths
    ) throws -> String {
        let directory = paths.sharedBin
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(tool.binary)

        // Only ever replace a link, and only ever one of ours.
        //
        // `removeItem` does not care what it is deleting, so an unconditional
        // replace would silently destroy a real file or a whole directory that
        // happened to share the name. Reading the link first tells the two
        // apart: `destinationOfSymbolicLink` succeeds only for a symlink.
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) {
            if existing == source { return destination.path }   // already right
            try FileManager.default.removeItem(at: destination)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            throw ToolError.destinationOccupied(destination.path)
        }

        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: URL(fileURLWithPath: source)
        )
        return destination.path
    }

    /// True when the sandbox's copy is a link this type created.
    ///
    /// The distinction the UI needs: a tool resolved from `shared/bin` is
    /// *reachable*, but "reachable because we linked it" and "reachable because
    /// it was installed there" call for different buttons — offering to remove
    /// an install the user made themselves would be wrong.
    public static func isLinked(tool: ToolDefinition, paths: SandboxPaths) -> Bool {
        let destination = paths.sharedBin.appendingPathComponent(tool.binary)
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil
    }

    /// Remove a link this type created. A no-op when there is nothing there.
    ///
    /// The inverse of `link`, and the inverse is why it only ever removes a
    /// *link*: unlinking must not be able to delete a file that was never ours.
    public static func unlink(tool: ToolDefinition, paths: SandboxPaths) throws {
        let destination = paths.sharedBin.appendingPathComponent(tool.binary)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil
        else { return }
        try FileManager.default.removeItem(at: destination)
    }
}

public enum ToolError: Error, LocalizedError, Equatable {
    case destinationOccupied(String)

    public var errorDescription: String? {
        switch self {
        case .destinationOccupied(let path):
            return "\(path) already exists and is not a link JXCode made, so it was left alone."
        }
    }
}
