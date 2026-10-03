import Foundation

/// Where the sandbox lives, chosen by the user.
///
/// The sandbox is a directory holding everything the agents touch: installed
/// tools, npm packages, model logs, saved workspaces. Its location used to be
/// fixed to Application Support with only an environment variable to change it,
/// which works for the test harness but not for a person — an env var is not a
/// thing a GUI can set for its own already-running process, and editing a
/// launch profile to change a directory is not something anyone should have to
/// do to move some caches onto a different disk.
///
/// Three rules make this safe to add:
///
/// 1. **The choice is stored outside the sandbox.** It lives in a fixed file in
///    Application Support, not inside the directory it points at. A pointer
///    inside the thing it points at cannot be read to find the thing, so the
///    first relocation would have nowhere to record itself and would be undone
///    by the next launch.
/// 2. **The environment still wins.** `JXCODE_ROOT` is how the CLI harness and
///    the tests keep their sandboxes away from the real one. A saved preference
///    must never outrank it, or a test run would write into the user's chosen
///    directory.
/// 3. **Moving relocates the data.** Choosing a new folder moves the existing
///    sandbox rather than leaving an empty one behind. An empty replacement
///    looks like success and is not: every agent has to be reinstalled, every
///    workspace re-created, and nothing says so.
public struct SandboxLocation: Codable, Equatable, Sendable {

    /// The directory the sandbox lives in.
    public var root: String

    public init(root: String) {
        self.root = root
    }

    /// Where the choice is recorded.
    ///
    /// A **sibling file, not a file inside the sandbox**. The first draft put
    /// it at `<sandbox>/location.json`, which is wrong in a way that only shows
    /// up after a move — and the test caught it before that could ship:
    ///
    /// - At the default location the pointer is *inside* the folder it names.
    /// - `move(to:)` moves that whole tree, so relocating the sandbox carried
    ///   the pointer with it.
    /// - The next launch looks for the pointer where it was left behind, does
    ///   not find it, falls back to the default — and the relocated sandbox,
    ///   now holding every installed agent, is orphaned in a folder nothing
    ///   points at.
    ///
    /// Sitting beside the sandbox rather than in it means no choice of location
    /// can ever swallow it. `move(to:)` refuses a destination that contains it
    /// as well, so a deliberately-chosen parent is caught rather than silently
    /// reproducing the same trap.
    public static var pointerFile: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("JXCode.location.json")
    }
}

/// Reads and writes the chosen sandbox location, and performs the move.
///
/// A type rather than a bare struct because the move is the whole reason the
/// setting exists and it has to be one operation: choose, move, and record, or
/// none of the three.
public struct SandboxLocationStore: Sendable {

    /// The shared file manager, reached rather than stored.
    ///
    /// Storing it made this type non-`Sendable` — `FileManager` is not
    /// `Sendable`, so a stored one stops the whole struct being sent across
    /// threads, and the compiler says so today and refuses outright under the
    /// Swift 6 language mode. Nothing is lost by asking for the singleton
    /// instead: `FileManager.default` returns the same object every time, so
    /// this held a reference to a global and implied it owned one.
    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Reading

    /// The built-in location, computed here rather than through
    /// `SandboxPaths.defaultRoot`.
    ///
    /// It **must** not delegate. `SandboxPaths.defaultRoot` is now defined as
    /// `SandboxLocationStore.resolvedRoot()`, so a `resolvedRoot` that ended by
    /// returning `SandboxPaths.defaultRoot` would call itself — forever, until
    /// the stack ran out. That is not a hypothetical: it shipped that way once,
    /// and the symptom was a segfault in `String._compressingSlashes` at
    /// startup on *every* command, including `--help`, with no output at all.
    /// A crash before `main` prints anything is very hard to attribute back to a
    /// one-line default, so the reasoning is written down here.
    public static var builtInRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("JXCode", isDirectory: true)
    }

    /// The root in force right now.
    ///
    /// Three sources, in this order, and the order is the contract:
    /// `JXCODE_ROOT` (harness and tests) → the saved choice → the built-in
    /// default. Anything that put the saved choice first would let a leftover
    /// preference in Application Support redirect a test run into the user's
    /// real directory.
    public static func resolvedRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["JXCODE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let saved = loadSaved(), !saved.root.isEmpty {
            return URL(fileURLWithPath: (saved.root as NSString).expandingTildeInPath)
        }
        return builtInRoot
    }

    /// The saved choice, or `nil` when there is none.
    ///
    /// A pointer that cannot be parsed is ignored rather than repaired: falling
    /// back to the default would point the app back at a directory the user
    /// deliberately moved away from, and re-recording the default would then
    /// make that fallback permanent.
    public static func loadSaved() -> SandboxLocation? {
        guard let data = try? Data(contentsOf: SandboxLocation.pointerFile),
              let location = try? JSONDecoder().decode(SandboxLocation.self, from: data)
        else { return nil }
        return location
    }

    /// The location in force, and whether the user chose it.
    ///
    /// Both halves are needed by the UI: "change…" must be offered against the
    /// directory actually in use, and a location inherited from an env var must
    /// be labelled as not-yet-chosen, because overwriting it would break the
    /// harness that set it.
    public static func current() -> (location: SandboxLocation, isUserChosen: Bool) {
        let env = ProcessInfo.processInfo.environment
        if let override = env["JXCODE_ROOT"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return (SandboxLocation(root: path), false)
        }
        if let saved = loadSaved() {
            return (saved, true)
        }
        return (SandboxLocation(root: SandboxPaths.defaultRoot.path), false)
    }

    // MARK: - Writing

    /// Point the sandbox at `path`, moving whatever is there.
    ///
    /// - Returns: a sentence for the user, or `nil` on success. The caller shows
    ///   it, so the move reports itself rather than changing the directory
    ///   silently — a sandbox that quietly relocates looks like data loss until
    ///   you go looking for it.
    @discardableResult
    public func move(to path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            return "Choose a folder first."
        }

        let destination = URL(fileURLWithPath: expanded).standardizedFileURL
        let current = Self.resolvedRoot().standardizedFileURL

        // Moving a directory onto itself is the one request that has no meaning:
        // it would ask for the source to contain the destination.
        guard destination != current else {
            record(SandboxLocation(root: destination.path))
            return nil
        }

        // Refuse a destination *inside* the current sandbox. The move would put
        // the sandbox inside itself and the copy would recurse until the disk
        // filled.
        if destination.path.hasPrefix(current.path + "/") {
            return "The new folder cannot sit inside the current sandbox (\(current.path))."
        }

        // Refuse a destination that would *contain* the pointer file. The
        // pointer records where the sandbox is, so a sandbox that swallows it
        // leaves the next launch with no way to find itself — and the moved
        // data ends up somewhere nothing refers to.
        if destination.path.hasPrefix(
            SandboxLocation.pointerFile.deletingLastPathComponent().path + "/"
        ) {
            return "\(destination.path) would contain the file that records the sandbox's location (\(SandboxLocation.pointerFile.path)). Pick a folder inside it instead."
        }

        let sourceExists = fileManager.fileExists(atPath: current.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)

        // A destination that already holds a sandbox must not be overwritten —
        // that is another install's agents and installed tools.
        if destinationExists && sourceExists {
            let looksLikeASandbox = fileManager.fileExists(
                atPath: destination.appendingPathComponent("env").path
            )
            if looksLikeASandbox {
                return "\(destination.path) already holds a sandbox. Choose an empty folder, or a folder that does not exist yet."
            }
            if let entries = try? fileManager.contentsOfDirectory(atPath: destination.path),
               !entries.isEmpty {
                return "\(destination.path) is not empty. Choose an empty folder so nothing there is disturbed."
            }
        }

        do {
            if sourceExists {
                // Move the whole tree. `replaceItemAt` is not right here: it
                // expects an existing item at the destination and the common
                // case is a destination that does not exist at all.
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: current, to: destination)
            } else {
                // Nothing to move — the sandbox has not been made yet. Create it
                // so the new location is real before it is recorded, otherwise a
                // failed create would still have moved the pointer.
                try fileManager.createDirectory(
                    at: destination, withIntermediateDirectories: true
                )
            }
        } catch {
            return "Could not move the sandbox to \(destination.path): \(error.localizedDescription)"
        }

        // Record only after the move worked. The other order would leave the
        // pointer naming a directory the failed move never created.
        record(SandboxLocation(root: destination.path))

        if sourceExists {
            let count = (try? fileManager.contentsOfDirectory(atPath: current.path))?.count ?? 0
            return count > 0
                ? "Sandbox moved to \(destination.path). Its \(count) top-level items came with it. Restart JXCode to use it."
                : "Sandbox moved to \(destination.path). Restart JXCode to use it."
        }
        return "Sandbox will be created at \(destination.path). Restart JXCode to use it."
    }

    /// Write the choice. Separate from `move` so a test can pin a location
    /// without touching the filesystem.
    @discardableResult
    public func record(_ location: SandboxLocation) -> Bool {
        do {
            try fileManager.createDirectory(
                at: SandboxLocation.pointerFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(location)
                .write(to: SandboxLocation.pointerFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Go back to the built-in default, moving nothing.
    ///
    /// Records the default as an explicit choice so the state is honest — the
    /// pointer file now says what it means rather than being absent and relying
    /// on a fallback nobody can see.
    @discardableResult
    public func resetToDefault() -> String? {
        let defaultRoot = SandboxPaths.defaultRoot
        if fileManager.fileExists(atPath: defaultRoot.path) {
            return move(to: defaultRoot.path)
        }
        return record(SandboxLocation(root: defaultRoot.path)) ? nil
            : "Could not record \(defaultRoot.path)."
    }
}
