import Foundation

/// A project group — the Origami "workspace" idea, with the directory living
/// inside the sandbox.
public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute path. Normally under `SandboxPaths.workspaces`, but a workspace
    /// may point at an existing host directory — the isolation is about the
    /// *toolchain*, not about hiding your code.
    public var path: String
    public var createdAt: Date
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        createdAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.notes = notes
    }

    /// Directory name derived from the workspace name.
    ///
    /// Spaces become hyphens; anything else outside `[a-z0-9-_]` is dropped.
    /// Runs of hyphens collapse and the result is trimmed, so a name that is all
    /// punctuation degrades to `workspace` rather than to `---`.
    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = name.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == " " { return "-" }
            return allowed.contains(scalar) ? Character(scalar) : nil
        }
        let slug = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return slug.isEmpty ? "workspace" : slug
    }
}

/// JSON-backed workspace persistence.
///
/// A plain file rather than a database: the whole point of this app is that
/// state is inspectable, and a file you can read and diff fits that.
public final class WorkspaceStore {

    public private(set) var workspaces: [Workspace] = []
    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
        load()
    }

    // MARK: - Persistence

    public func load() {
        guard let data = try? Data(contentsOf: paths.workspacesFile) else {
            workspaces = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        workspaces = (try? decoder.decode([Workspace].self, from: data)) ?? []
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(workspaces).write(to: paths.workspacesFile, options: .atomic)
    }

    // MARK: - Mutation

    /// Create a workspace with a directory inside the sandbox.
    ///
    /// The directory lands under `base`, which is `SandboxPaths.workspaces` by
    /// default. A custom base is how a workspace can be created somewhere the
    /// user chose — a project root on the host, a second volume — while the
    /// *toolchain* isolation is unchanged: what a workspace gets is the
    /// environment, not the directory's parent.
    @discardableResult
    public func create(name: String, in base: URL? = nil) throws -> Workspace {
        let slug = Workspace.slug(name)
        let base = base ?? paths.workspaces
        var candidate = base.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)

        let workspace = Workspace(name: name, path: candidate.path)
        workspaces.append(workspace)
        try save()
        return workspace
    }

    /// Adopt an existing directory as a workspace.
    ///
    /// Adopting a path that is already a workspace **returns the existing one**
    /// rather than adding a second row for the same folder.
    ///
    /// This used to append unconditionally, which means running `jxcode adopt`
    /// twice on one folder gave you two workspaces pointing at one directory,
    /// and the sidebar showed the folder twice with the same name and no way to
    /// tell them apart. That is not hypothetical: it is what happened while this
    /// was being tested, and the list grew to eleven rows for four folders.
    ///
    /// The comparison is the same canonical-path rule `ProjectFolders.key`
    /// uses — resolve `.` and `..`, compare case-insensitively — because macOS
    /// volumes are case-insensitive by default and `/Users/x/Proj` and
    /// `/Users/x/proj` are one directory. A separate rule here would mean two
    /// spellings of one folder producing one row here and two there.
    ///
    /// Also records the folder in the sidebar's recent list, and that is here
    /// rather than in the callers on purpose. There are three ways into this —
    /// the app's adopt sheet, a click on a folder row, and `jxcode adopt` from
    /// the terminal — and recording it in the caller meant the CLI silently
    /// produced a different history from the window.
    ///
    /// A failure to record is not a failure to adopt. The workspace exists and
    /// the user asked for it; losing a sidebar entry is recoverable by opening
    /// the folder again, whereas refusing the workspace over it would not be.
    @discardableResult
    public func adopt(name: String, path: String) throws -> Workspace {
        let key = ProjectFolders.key(for: path)
        if let existing = workspaces.first(where: { ProjectFolders.key(for: $0.path) == key }) {
            // Re-recording the visit is the point of re-adopting, so the recent
            // list still learns the folder was used just now.
            var folders = ProjectFolderStore(paths: paths).load()
            folders.recordVisit(path: existing.path, name: existing.name)
            // `save` answers a `Bool` and does not throw, so the `try?` that
            // stood here was noise: it changed nothing and left the discarded
            // result as a compiler warning. The recent-folder list is a
            // convenience, and failing the adopt because it could not be
            // written would be the wrong trade — same reason
            // `ProjectFolderStore.load()` treats an unreadable file as empty.
            ProjectFolderStore(paths: paths).save(folders)
            return existing
        }

        let workspace = Workspace(name: name, path: path)
        workspaces.append(workspace)
        try save()

        var folders = ProjectFolderStore(paths: paths).load()
        folders.recordVisit(path: path, name: name)
        ProjectFolderStore(paths: paths).save(folders)

        return workspace
    }

    public func rename(id: UUID, to name: String) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        try save()
    }

    /// Forget a workspace. The directory on disk is left alone — deleting user
    /// files is never implicit.
    public func remove(id: UUID) throws {
        workspaces.removeAll { $0.id == id }
        try save()
    }

    public func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }
}
