import Foundation
import JXCodeCore

/// `jxcode folders` — the folders worked in, and the sandbox's own location.
///
/// Two questions that both live in one file on disk and are both "where is
/// everything", grouped because they are both answered by looking rather than
/// by changing anything. `folders` lists, `folder-pin` changes, `folder-forget`
/// removes, `sandbox` reports and `sandbox-move` relocates.
enum FolderCommands {

    // MARK: folders

    static func list(_ flags: Flags) throws {
        let store = ProjectFolderStore(paths: .default)
        let folders = store.load()

        if flags.has("--json") {
            Console.line(Self.json(folders))
            return
        }

        if folders.entries.isEmpty {
            Console.line("No folders yet.")
            Console.line("Open one with: jxcode adopt <path>")
            return
        }

        let pinned = folders.pinned
        if !pinned.isEmpty {
            Console.line("PINNED")
            for entry in pinned {
                Console.line("  \(pad(entry.name, 24))\(presence(entry))")
                Console.line("  \(pad("", 24))\(entry.path)")
            }
        }

        let recent = folders.recent
        if !recent.isEmpty {
            Console.blank()
            Console.line("RECENT")
            for entry in recent {
                Console.line("  \(pad(entry.name, 24))\(presence(entry))")
                Console.line("  \(pad("", 24))\(entry.path)")
            }
        }

        // The rest, so nothing is silently invisible just because it fell out of
        // the capped recent list.
        let shown = Set(pinned.map(\.path) + recent.map(\.path))
        let rest = folders.entries
            .filter { !shown.contains($0.path) }
            .sorted { $0.lastOpened > $1.lastOpened }
        if !rest.isEmpty {
            Console.blank()
            Console.line("OLDER (\(rest.count))")
            for entry in rest.prefix(20) {
                Console.line("  \(pad(entry.name, 24))\(presence(entry))")
            }
            if rest.count > 20 {
                Console.line("  … and \(rest.count - 20) more")
            }
        }

        Console.blank()
        Console.line("file: \(store.fileURL.path)")
    }

    /// `jxcode folder-pin <path> [--off]` — pin or unpin a folder.
    static func pin(_ flags: Flags) throws {
        guard let raw = flags.positional.first else {
            throw CLIError.usage("jxcode folder-pin <path> [--off]")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let store = ProjectFolderStore(paths: .default)
        var folders = store.load()

        let key = ProjectFolders.key(for: expanded)
        guard folders.entries.contains(where: { ProjectFolders.key(for: $0.path) == key }) else {
            throw CLIError.usage("\(expanded) is not in the list. Open it first: jxcode adopt \(expanded)")
        }

        // No `--on` needed: pinning something already pinned is a no-op the user
        // did not ask for, and having to type the direction invites a typo that
        // unpins something.
        let shouldPin = !flags.has("--off")
        guard folders.setPinned(shouldPin, path: expanded) else {
            Console.line(shouldPin ? "Already pinned." : "Already unpinned.")
            return
        }
        guard store.save(folders) else {
            throw CLIError.io("could not write \(store.fileURL.path)")
        }
        Console.line(shouldPin ? "Pinned \(expanded)" : "Unpinned \(expanded)")
    }

    /// `jxcode folder-forget <path>` — remove a folder from both lists.
    static func forget(_ flags: Flags) throws {
        guard let raw = flags.positional.first else {
            throw CLIError.usage("jxcode folder-forget <path>")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let store = ProjectFolderStore(paths: .default)
        var folders = store.load()

        guard folders.remove(path: expanded) else {
            throw CLIError.usage("\(expanded) is not in the list.")
        }
        guard store.save(folders) else {
            throw CLIError.io("could not write \(store.fileURL.path)")
        }
        Console.line("Removed \(expanded)")
    }

    // MARK: sandbox

    /// `jxcode sandbox` — where the sandbox is and what is in it.
    static func sandbox(_ flags: Flags) throws {
        let current = SandboxLocationStore.current()
        let paths = SandboxPaths.default

        if flags.has("--json") {
            Console.line(Self.json([
                "root": current.location.root,
                "chosenByUser": current.isUserChosen,
                "pointerFile": SandboxLocation.pointerFile.path,
            ]))
            return
        }

        Console.line("Sandbox folder")
        Console.line("  path      \(current.location.root)")
        Console.line("  chosen by \(current.isUserChosen ? "you" : "JXCODE_ROOT (command line / tests)")")
        Console.line("  pointer   \(SandboxLocation.pointerFile.path)")
        Console.blank()

        if !current.isUserChosen {
            Console.line("This run has its folder forced from outside, so it ignores")
            Console.line("the saved choice. A normal launch does not.")
            Console.blank()
        }

        let items = (try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)) ?? []
        Console.line("Contents: \(items.count) top-level item\(items.count == 1 ? "" : "s")")
        for name in items.sorted().prefix(20) {
            Console.line("  \(name)")
        }
        if items.count > 20 {
            Console.line("  … and \(items.count - 20) more")
        }
        Console.blank()
        Console.line("Change it with: jxcode sandbox-move <path>")
    }

    /// `jxcode sandbox-move <path>` — relocate the sandbox.
    static func sandboxMove(_ flags: Flags) throws {
        guard let raw = flags.positional.first else {
            throw CLIError.usage("jxcode sandbox-move <path>")
        }
        let store = SandboxLocationStore()
        if let message = store.move(to: raw) {
            throw CLIError.io(message)
        }
        Console.line("Sandbox moved to \((raw as NSString).expandingTildeInPath)")
        Console.line("Start a new jxcode session for it to take effect.")
    }

    /// `jxcode sandbox-reset` — go back to the built-in default folder.
    static func sandboxReset() throws {
        let store = SandboxLocationStore()
        if let message = store.resetToDefault() {
            throw CLIError.io(message)
        }
        Console.line("Sandbox will be at \(SandboxPaths.defaultRoot.path)")
        Console.line("Start a new jxcode session for it to take effect.")
    }

    // MARK: Helpers

    /// Right-pad to a column, without `padding(toLength:)` counting UTF-16 units.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count < width
            ? text + String(repeating: " ", count: width - text.count)
            : text + " "
    }

    private static func presence(_ entry: ProjectFolders.Entry) -> String {
        FileManager.default.fileExists(atPath: entry.path) ? "ok" : "missing"
    }

    private static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func json(_ folders: ProjectFolders) -> String {
        let payload: [String: Any] = [
            "file": ProjectFolderStore(paths: .default).fileURL.path,
            "entries": folders.entries.map { entry in
                [
                    "path": entry.path,
                    "name": entry.name,
                    "pinned": entry.isPinned,
                    "visits": entry.visitCount,
                    "lastOpened": ISO8601DateFormatter().string(from: entry.lastOpened),
                    "present": FileManager.default.fileExists(atPath: entry.path),
                ] as [String: Any]
            },
        ]
        return json(payload as Any)
    }
}
