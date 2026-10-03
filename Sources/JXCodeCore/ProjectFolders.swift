import Foundation

/// The folders a person has worked in, split into the two lists a sidebar wants.
///
/// Split by intent rather than by recency alone, because those are two different
/// questions. "What did I work on lately" and "what do I always want to hand"
/// are answered by different rules, and a single time-sorted list forces the
/// user to re-find the folder they use every day the moment it ages out.
///
/// Pinning is a claim about *intent* — "this one is always wanted" — so it
/// survives the recency window and survives the folder disappearing. That last
/// part matters: a pin whose folder was deleted is kept, greyed, with a
/// "missing" note. Dropping it silently would mean the user's declared
/// favourite could vanish because of something that happened to it on disk,
/// and re-pinning it means remembering which of several similarly named projects
/// it was.
public struct ProjectFolders: Codable, Equatable, Sendable {

    /// One folder the person works in.
    public struct Entry: Codable, Equatable, Hashable, Identifiable, Sendable {
        /// Stable identity across renames and re-visits.
        ///
        /// The resolved path, not a UUID: the same folder must collect its own
        /// history however it is reached, and a UUID minted per visit would
        /// treat every visit as a new project. On a case-insensitive volume the
        /// path is lowercased, or `/Users/x/Proj` and `/Users/x/proj` would
        /// become two folders in the list that are the same directory.
        public var path: String

        /// The directory's own name, so the row reads as the folder even when it
        /// sits under a parent nobody recognises.
        public var name: String

        /// When this folder was last opened. Drives the recent list's order.
        public var lastOpened: Date

        /// How many times it has been opened. Shown as a quiet number — it is
        /// the honest signal for "which of these do I actually use", which
        /// recency alone gets wrong for a folder opened twice in one afternoon.
        public var visitCount: Int

        /// Whether the person pinned it.
        public var isPinned: Bool

        public var id: String { path }

        public init(
            path: String,
            name: String,
            lastOpened: Date = Date(),
            visitCount: Int = 1,
            isPinned: Bool = false
        ) {
            self.path = path
            self.name = name
            self.lastOpened = lastOpened
            self.visitCount = visitCount
            self.isPinned = isPinned
        }
    }

    /// Every folder ever opened, pinned or not, newest visit kept per path.
    ///
    /// This is the whole history and both lists are derived from it, so the two
    /// can never disagree — a folder cannot be recent but not present, and
    /// unpinning cannot lose the recency.
    public var entries: [Entry]

    /// How many folders the recent list shows before it stops.
    ///
    /// A cap, because a sidebar column has a height and an uncapped list simply
    /// pushes "Sandbox / Router / Local model" — the status rows a person
    /// checks constantly — off the bottom. Eight rows is what fits above the
    /// service rows in the current sidebar at its 244pt width.
    public static let recentLimit = 8

    /// The folders to show as recent: not pinned, ordered by last opened.
    public var recent: [Entry] {
        entries
            .filter { !$0.isPinned }
            .sorted { $0.lastOpened > $1.lastOpened }
            .prefix(Self.recentLimit)
            .map { $0 }
    }

    /// The folders to show as pinned, in the order the person arranged them.
    public var pinned: [Entry] {
        entries
            .filter(\.isPinned)
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: - Recording a visit

    /// Note that `path` was opened.
    ///
    /// One entry per path, always: a repeated visit bumps the timestamp and the
    /// count rather than appending a duplicate. The name is refreshed from disk
    /// each time, so a folder renamed on disk shows its new name here instead of
    /// the name it had the first time it was opened.
    public mutating func recordVisit(path: String, name: String? = nil, at date: Date = Date()) {
        let key = Self.key(for: path)
        let resolvedName = name ?? (path as NSString).lastPathComponent

        if let index = entries.firstIndex(where: { Self.key(for: $0.path) == key }) {
            entries[index].name = resolvedName.isEmpty ? entries[index].name : resolvedName
            // Never move a folder backwards in time. The clock can jump, an iCloud
            // restore can hand back an older timestamp, and a folder that suddenly
            // sorts to the bottom of "recent" because of a clock correction reads
            // as the app having forgotten it.
            if date > entries[index].lastOpened {
                entries[index].lastOpened = date
            }
            entries[index].visitCount += 1
        } else {
            entries.append(
                Entry(path: path, name: resolvedName, lastOpened: date, visitCount: 1)
            )
        }
    }

    /// Pin or unpin a folder.
    ///
    /// Returns whether it changed, so the caller can tell "user unpinned" from
    /// "user clicked an already-unpinned folder" and skip a pointless redraw.
    @discardableResult
    public mutating func setPinned(_ pinned: Bool, path: String) -> Bool {
        let key = Self.key(for: path)
        guard let index = entries.firstIndex(where: { Self.key(for: $0.path) == key }) else {
            return false
        }
        guard entries[index].isPinned != pinned else { return false }
        entries[index].isPinned = pinned
        return true
    }

    /// Forget a folder entirely — the pin *and* the history.
    ///
    /// Separate from `setPinned(false)` because "unpin" says "not a favourite,
    /// but I still work here" and "forget" says "I have never worked here". The
    /// second has to be able to remove a folder that is missing from disk, which
    /// is the case where keeping it would only ever show a dead row.
    @discardableResult
    public mutating func remove(path: String) -> Bool {
        let key = Self.key(for: path)
        let before = entries.count
        entries.removeAll { Self.key(for: $0.path) == key }
        return entries.count != before
    }

    /// Whether a folder is still on disk.
    ///
    /// Checked live rather than stored: a folder can be moved or unmounted
    /// between launches, and a stored answer would go stale while looking
    /// authoritative.
    public func isPresent(_ entry: Entry) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: entry.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// One canonical spelling of a path, so the same folder is one entry.
    ///
    /// Standardised (resolving `.` and `..`) and lowercased. The lowercasing is
    /// the part that is easy to leave out and expensive to debug: macOS volumes
    /// are case-insensitive by default, so two spellings of one directory are
    /// two rows pointing at one place, and pinning one of them looks broken.
    ///
    /// Public because the CLI needs the same comparison when pinning: it has to
    /// decide "is this path already in the list" with the identical rule the
    /// store used to add it, or `folder-pin` would reject a folder that is
    /// plainly there because it was recorded under a different spelling.
    public static func key(for path: String) -> String {
        let standardized = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: standardized).standardizedFileURL.path
        return resolved.lowercased()
    }
}

/// Reads and writes the project folder list.
///
/// Its own file beside the other saved state, not part of `workspaces.json`:
/// this list is a memory of where someone has been, while a workspace is a
/// configured thing they asked for. Conflating them means deleting a workspace
/// silently erases the record that they worked there, and the folders would be
/// lost to a tidiness action that had nothing to do with them.
public struct ProjectFolderStore: Sendable {

    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
    }

    public var fileURL: URL { paths.state.appendingPathComponent("folders.json") }

    /// The saved list, or an empty one.
    ///
    /// The decoder must be told `.iso8601` to match `save()`. Without it the
    /// encoder writes `"2026-10-01T16:51:50Z"` and the decoder expects a
    /// `Double`, every read fails, and the list silently comes back empty —
    /// which is exactly what it did: folders recorded correctly, then reported
    /// "No folders yet" every time. A store that can only fail by being empty
    /// is a store whose failure looks like a fresh install.
    ///
    /// A decode failure is still treated as "no folders" rather than an error,
    /// for the same reason `PrimaryAgentStore.load()` does: this is a
    /// convenience list, and refusing to start the app because it could not be
    /// parsed would be a bad trade. The cost of losing it is one click.
    public func load() -> ProjectFolders {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let folders = try? decoder.decode(ProjectFolders.self, from: data)
        else { return ProjectFolders() }
        return folders
    }

    @discardableResult
    public func save(_ folders: ProjectFolders) -> Bool {
        (try? saveChecked(folders)) != nil
    }

    /// The same write as `save`, but it throws.
    ///
    /// `save` answering `false` tells a caller that the write failed and
    /// nothing else — not which file, not why. That is enough to skip the
    /// update, and it is what the app did: a pin or a forget that could not be
    /// written left the click doing nothing at all, with no message, because a
    /// `Bool` carries no reason to show. This carries the reason.
    public func saveChecked(_ folders: ProjectFolders) throws {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Sorted dates read as a jumble in a hand-edited file and are never
        // edited by hand, so ISO strings are friendlier than epoch doubles.
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(folders).write(to: fileURL, options: .atomic)
    }

    /// Forget everything. For a "clear the list" affordance, and for a test
    /// fixture that wants a known-empty start.
    @discardableResult
    public func clear() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }
}
