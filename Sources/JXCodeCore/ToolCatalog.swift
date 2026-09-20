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
public struct ToolDefinition: Identifiable, Hashable, Sendable {

    public let id: String
    public let name: String
    /// The executable looked up on `PATH`.
    public let binary: String
    /// Passed on launch. Empty for a tool that opens its own interface.
    public let arguments: [String]
    /// One line for the card, in the same voice as an agent's tagline.
    public let tagline: String

    public init(
        id: String,
        name: String,
        binary: String,
        arguments: [String] = [],
        tagline: String
    ) {
        self.id = id
        self.name = name
        self.binary = binary
        self.arguments = arguments
        self.tagline = tagline
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
