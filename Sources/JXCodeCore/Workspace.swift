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
    @discardableResult
    public func create(name: String) throws -> Workspace {
        let slug = Workspace.slug(name)
        var candidate = paths.workspaces.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = paths.workspaces.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)

        let workspace = Workspace(name: name, path: candidate.path)
        workspaces.append(workspace)
        try save()
        return workspace
    }

    /// Adopt an existing directory as a workspace.
    @discardableResult
    public func adopt(name: String, path: String) throws -> Workspace {
        let workspace = Workspace(name: name, path: path)
        workspaces.append(workspace)
        try save()
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
