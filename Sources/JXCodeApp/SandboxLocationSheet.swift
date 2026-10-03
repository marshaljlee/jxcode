import AppKit
import JXCodeCore
import SwiftUI

// MARK: - Choosing where the sandbox lives

/// Pick the folder the sandbox lives in.
///
/// The sandbox is one directory holding everything the agents touch: the tools
/// installed into them, their npm packages, model logs, saved workspaces. It
/// defaulted to Application Support and could only be changed by editing an
/// environment variable in a launch profile, which is not a thing a window can
/// offer and not a thing anyone should have to do to move caches to a faster
/// disk.
///
/// The panel leads with the folder and what is in it, because the question is
/// never "where would you like this" but "what are you about to move, and what
/// comes with it". A directory the user cannot see the size of is a directory
/// they will guess about.
struct SandboxLocationSheet: View {
    @EnvironmentObject private var state: AppState

    @State private var path: String = ""
    @State private var outcome: String?
    @State private var failed = false
    @State private var sizeText: String?
    @State private var itemCount: Int?

    /// Counts `measure` runs so a slow walk can tell it has been superseded.
    @State private var measureGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("FOLDER")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 8) {
                    TextField("~/Library/Application Support/JXCode", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit(apply)
                    Button("Choose…", action: choose)
                }
                if let sizeText, let itemCount {
                    Text("\(itemCount) top-level item\(itemCount == 1 ? "" : "s"), \(sizeText) on disk")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("Nothing there yet — the folder will be created.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if let outcome {
                Text(outcome)
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? Theme.warning : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            facts

            HStack {
                Button("Back to the default") { applyDefault() }
                    .controlSize(.small)
                Spacer()
                Button("Cancel") { state.showSandboxLocation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move it here", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: seed)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where the sandbox lives")
                .font(.system(size: 15, weight: .medium))
            Text("Everything the agents install and write goes in this one folder.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// What is actually in force, and whether the user chose it.
    ///
    /// The distinction matters: a location inherited from `JXCODE_ROOT` is the
    /// test harness speaking, and overwriting it would break the thing that set
    /// it. So it is shown as inherited and the move button explains why it is
    /// the way it is.
    private var facts: some View {
        let current = SandboxLocationStore.current()
        return VStack(alignment: .leading, spacing: 5) {
            fact("In use now", current.location.root)
            fact(
                "Chosen by",
                current.isUserChosen
                    ? "you, in this app"
                    : "JXCODE_ROOT (the command line and tests)"
            )
            if !current.isUserChosen {
                Text("This build was started with a location forced from outside, so "
                     + "changing it here takes effect on the next normal launch.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func seed() {
        let current = SandboxLocationStore.current()
        path = current.location.root
        measure(path)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            measure(path)
        }
    }

    private func apply() {
        let store = SandboxLocationStore()
        if let message = store.move(to: path) {
            failed = true
            outcome = message
            return
        }
        failed = false
        outcome = "Moved. Quit and reopen JXCode to use the new folder. "
            + "The sandbox is read once at launch, and moving it underneath a "
            + "running router is how a session ends up writing into a folder "
            + "that is no longer there."
    }

    private func applyDefault() {
        let store = SandboxLocationStore()
        if let message = store.resetToDefault() {
            failed = true
            outcome = message
            return
        }
        let defaultRoot = SandboxPaths.defaultRoot
        path = defaultRoot.path
        failed = false
        outcome = "Using the default folder. Quit and reopen JXCode."
        measure(path)
    }

    /// How big the chosen folder is, and how many things are in it.
    ///
    /// Shown before the move, not after: the whole reason to look at this panel
    /// is to decide whether the folder is the right size for what is going into
    /// it, and a number that only appears once the move is done cannot inform
    /// that decision.
    private func measure(_ candidate: String) {
        let expanded = (candidate as NSString).expandingTildeInPath

        // A newer measurement invalidates any walk still running. Picking a
        // second folder must not be overwritten by the first folder's walk
        // finishing late — the number would then describe a folder the user has
        // already moved away from.
        measureGeneration += 1
        let generation = measureGeneration

        guard FileManager.default.fileExists(atPath: expanded) else {
            itemCount = nil
            sizeText = nil
            return
        }

        // The walk reads up to 20,000 entries and is called from `.onAppear`,
        // from a button and from a panel dismissal — all on the main actor,
        // where a freeze of a few hundred milliseconds is visible as a stalled
        // sheet. It touches no UI state and reads no shared value, so it is
        // moved off rather than throttled: there is no repeated-event problem
        // to solve here, only one expensive call that does not belong on the
        // thread that draws.
        Task.detached(priority: .userInitiated) {
            let entries = try? FileManager.default.contentsOfDirectory(atPath: expanded)
            let size = Self.byteCount(at: URL(fileURLWithPath: expanded))
            await MainActor.run {
                guard generation == measureGeneration else { return }
                itemCount = entries?.count
                sizeText = size
            }
        }
    }

    /// A human-readable total for a directory, by walking it once.
    ///
    /// `URL.resourceValues(.fileSizeKey)` reports only the directory node, not
    /// what is inside, so the common shortcut returns "0 bytes" for a folder
    /// holding several gigabytes of installed agents — a number that is not just
    /// wrong but confidently wrong, which is worse than none. So it walks.
    ///
    /// Bounded by `maxEntries`: a sandbox with a few tens of thousands of files
    /// in it (node_modules alone will do it) would otherwise take long enough
    /// that the sheet stops responding on open. Past the bound the answer is
    /// marked approximate rather than silently truncated to a wrong total.
    nonisolated private static func byteCount(at url: URL, maxEntries: Int = 20_000) -> String {
        var total: Int64 = 0
        var counted = 0

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return "unknown" }

        for case let entry as URL in enumerator {
            if counted >= maxEntries { return "~\(format(total))+ (stopped early)" }
            guard let values = try? entry.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
                counted += 1
            }
        }
        return format(total)
    }

    /// Bytes as a short string.
    nonisolated static func format(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [
            (1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB"),
        ]
        for (scale, name) in units where bytes >= scale {
            return String(format: "%.1f %@", Double(bytes) / Double(scale), name)
        }
        return "\(bytes) bytes"
    }
}
