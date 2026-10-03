import Foundation

/// The two sidecars JXCode leaves beside a config file, and the rule that
/// connects them.
///
/// Four writers in this module touch config files an agent also owns, and all
/// four need the same two answers: *may I modify this?* and *did the user have
/// it first?*. Both answers come from the filesystem, so the logic lives here
/// rather than in four identical private copies — the moment one copy learns
/// something the others do not, the same file gets treated differently
/// depending on which binder reached it last.
///
/// The bug that forced the consolidation is worth stating, because it is quiet.
/// `hasBackup` reads "a backup exists" as "the user had this file before JXCode
/// did", and that is what makes it safe to delete the file again on revert. The
/// inference only holds while exactly one writer touches a file. Several do:
/// `opencode.json` holds both the MCP servers and the skill permission, every
/// agent's instruction file holds both the skill list and the system prompt, and
/// `config.toml` holds both the MCP servers and the model overrides. The second
/// writer to arrive found the first writer's file, backed it up, and recorded
/// the **user** as its author — after which revert declined to delete a file
/// that was entirely ours and left `{}` behind where there should be nothing.
///
/// So creation is recorded rather than inferred.
///
/// The record covers **directories** as well as files, and it is deliberately
/// the same record: the same sidecar, the same two questions, the same rule
/// that a thing we created is removed rather than left behind. The file rule
/// used to stop at directories, and the two that survived a full bind-and-
/// unbind cycle — `~/.claude/skills/` and `~/.config/opencode/` — were the
/// visible half of that. `~/.agents/` and `~/.agents/skills/` were the half
/// nobody had looked at, because `createDirectory` makes every missing
/// ancestor and reports none of them.
public enum ConfigFiles {

    // MARK: - The sidecars

    /// The copy of a file as it was before JXCode first wrote to it.
    public static func backupURL(of file: URL) -> URL {
        file.appendingPathExtension("jxcode-backup")
    }

    /// The record that JXCode created the file or directory, rather than
    /// finding it.
    ///
    /// A *sibling* in both cases, including for a directory. A marker inside
    /// the directory was rejected on purpose: it would make the directory
    /// non-empty by construction, so the "is it empty" guard below could never
    /// hold, and a removal that failed would take the marker with it and leave
    /// a directory with nothing on disk to say whose it was.
    public static func createdURL(of file: URL) -> URL {
        file.appendingPathExtension("jxcode-created")
    }

    // MARK: - Writing

    /// Copy `file` aside once, before the first modification.
    ///
    /// Skipped if a backup already exists, so a second run cannot overwrite a
    /// good backup with an already-modified file — which would turn the safety
    /// net into a decoy recording our own content as the user's.
    ///
    /// Skipped too when JXCode created the file. There is nothing to preserve,
    /// and taking a backup would make the opposite claim.
    public static func backUp(_ file: URL) {
        guard !isCreated(byJXCode: file) else { return }
        let backup = backupURL(of: file)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: file, to: backup)
    }

    /// Whether a backup exists — the record that the file predated JXCode.
    ///
    /// This doubles as the licence to delete the file on revert: the state to
    /// restore is "no file", not "an empty one", and a `settings.json` left as
    /// `{}` makes "never configured" and "configured, then unbound" look
    /// identical on disk.
    public static func hasBackup(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(of: file).path)
    }

    // MARK: - Ownership

    /// Whether JXCode created `file`, rather than finding it already there.
    public static func isCreated(byJXCode file: URL) -> Bool {
        FileManager.default.fileExists(atPath: createdURL(of: file).path)
    }

    /// Record that `file` did not exist before JXCode wrote it.
    ///
    /// Never fails loudly. A marker that cannot be written costs a leftover `{}`
    /// on some later revert, which is not worth refusing a bind over — and
    /// refusing here would mean a bind that reports failure having already
    /// written the config it was complaining about.
    public static func markCreated(_ file: URL) {
        try? Data().write(to: createdURL(of: file))
    }

    /// Forget the record, because the file it describes is gone.
    ///
    /// Leaving the marker behind is not harmless: the next writer to create a
    /// file at that path would inherit the claim, and a file the user later
    /// wrote by hand would be deleted as ours.
    public static func clearCreated(_ file: URL) {
        try? FileManager.default.removeItem(at: createdURL(of: file))
    }

    /// Remove `file`, and forget that we created it.
    ///
    /// The two always go together, so they are one call: a removal that forgot
    /// the marker leaves a claim on a path nobody owns, and a marker cleared
    /// without the removal leaves a file that looks like the user's.
    public static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        clearCreated(file)
    }

    // MARK: - Directories

    /// Create `directory` and every missing parent, recording which of them
    /// JXCode created.
    ///
    /// `createDirectory(withIntermediateDirectories: true)` makes an unknown
    /// number of ancestors and reports none of them, so ownership has to be
    /// worked out *before* the call: every path from `directory` up to the
    /// first one that already exists is one this call is about to make. Without
    /// that, a bind that created `~/.agents/skills/` recorded nothing about
    /// `~/.agents/`, and an unbind had no way to know it had made either.
    ///
    /// `boundary` is the sandbox home. Ownership is only recorded inside it,
    /// because that is the tree the removal walk covers; a target outside it is
    /// created the ordinary way and left unowned rather than claimed by a
    /// marker the sweep would never reach.
    ///
    /// Returns the directories it created, deepest first.
    @discardableResult
    public static func createDirectory(at directory: URL, upTo boundary: URL) throws -> [URL] {
        let manager = FileManager.default

        guard directory.isContained(in: boundary) else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            return []
        }

        var owned: [URL] = []
        var current = directory.standardizedFileURL
        // `isContained(in:)` is false for the boundary itself, so the walk stops
        // at the sandbox home rather than claiming it.
        while current.isContained(in: boundary),
              !manager.fileExists(atPath: current.path) {
            owned.append(current)
            current = current.deletingLastPathComponent()
        }

        guard !owned.isEmpty else { return [] }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in owned { markCreated(path) }
        return owned
    }

    /// Take back the directories a bind created, and describe each removal.
    ///
    /// Walks *upward* from each candidate rather than trusting the list:
    /// creating `~/.agents/skills/` also creates `~/.agents/`, so removing only
    /// the deepest would leave the parent behind — the same defect one level up,
    /// which is exactly how the first version of the file rule was wrong. The
    /// walk stops at the first directory that is not ours, is not empty, or is
    /// outside `boundary`.
    ///
    /// Empty is the second half of the rule, and it is not the same as ours. A
    /// directory we created can acquire the user's own files afterwards, and the
    /// marker authorises removing the container we made — not anything inside
    /// it. A `*.jxcode-backup` sitting in one of these directories is the same
    /// case: it means a file in there predated JXCode, so the directory stays.
    ///
    /// Returns one message per removal, in the same voice as the file rule, so
    /// the CLI, the pane and the verification script cannot describe the same
    /// act three ways.
    @discardableResult
    public static func removeCreatedDirectories(
        _ directories: [URL],
        upTo boundary: URL
    ) -> [String] {
        let manager = FileManager.default
        var messages: [String] = []

        for candidate in directories {
            var current = candidate.standardizedFileURL
            while current.isContained(in: boundary),
                  isCreated(byJXCode: current),
                  isEmptyDirectory(current) {
                try? manager.removeItem(at: current)
                clearCreated(current)
                messages.append("removed \(current.path), an empty directory the bind created")
                current = current.deletingLastPathComponent()
            }
        }

        return messages
    }

    /// Whether `url` is a directory with nothing in it.
    ///
    /// A path that is not a directory, or does not exist, answers `false` —
    /// `contentsOfDirectory` throws on both — which is the safe direction: the
    /// walk above stops instead of removing something it could not inspect.
    ///
    /// A symlink is not guarded *here*, and does not need to be: this reads
    /// through the link, so a link to an empty directory answers `true`. What
    /// keeps a symlink safe is the marker, not this test — `fileExists` also
    /// follows links, so a link whose target exists is never recorded as
    /// created and the walk stops before it. A *dangling* link is the gap, and
    /// it fails earlier still: `createDirectory` refuses the path outright, so
    /// the bind stops with an error rather than claiming the directory. That is
    /// recorded in the README's known limitations rather than fixed here.
    private static func isEmptyDirectory(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty) ?? false
    }
}
