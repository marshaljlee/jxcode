import AppKit
import JXCodeCore
import SwiftUI

// MARK: - Recent and pinned project folders

/// The folders the person works in, split into pinned and recent.
///
/// Two lists rather than one time-sorted list, because they answer different
/// questions and a single list answers neither well. "What did I work on" is
/// answered by recency; "what do I always want to hand" is a claim the person
/// makes once and should not have to re-make every week. Sorting those together
/// means the folder someone uses every day drops off the bottom of the list
/// after a quiet fortnight and has to be hunted for again.
///
/// Pinned rows come first and are never capped: a pin the user made is a
/// decision, and a list that silently drops decisions is not a pin list. Recent
/// is capped, because a sidebar is a fixed height and the status rows beneath it
/// are read constantly.
struct ProjectFoldersSection: View {
    @EnvironmentObject private var state: AppState
    @State private var hoveredPath: String?

    private var pinned: [ProjectFolders.Entry] { state.folders.pinned }
    private var recent: [ProjectFolders.Entry] { state.folders.recent }

    /// Whether this folder is the workspace currently open.
    ///
    /// Matched on the resolved path rather than the name, because the folder
    /// list and the workspace list are built independently and the same folder
    /// can be spelled either way. `ProjectFolders.key` is the comparison the
    /// store already uses for "is this the same folder", so reusing it keeps the
    /// highlight and the dedup rule from disagreeing.
    private func isActive(_ entry: ProjectFolders.Entry) -> Bool {
        guard let workspace = state.selectedWorkspace else { return false }
        return ProjectFolders.key(for: workspace.path) == ProjectFolders.key(for: entry.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pinned.isEmpty {
                header("PINNED", count: pinned.count)
                ForEach(pinned) { entry in
                    row(entry)
                }
            }

            if !recent.isEmpty {
                header(
                    "RECENT",
                    count: recent.count,
                    trailing: state.folders.entries.count > ProjectFolders.recentLimit
                        ? "\(state.folders.entries.count) total"
                        : nil
                )
                ForEach(recent) { entry in
                    row(entry)
                }
            }
        }
    }

    private func header(_ text: String, count: Int, trailing: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(text)
                // The one place in the sidebar that gets bold + capitals: a
                // section heading has to announce itself without competing with
                // the folder names under it. Everything else is regular.
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary.opacity(0.7))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    @ViewBuilder
    private func row(_ entry: ProjectFolders.Entry) -> some View {
        let isHovering = hoveredPath == entry.path
        let present = state.folders.isPresent(entry)

        Button {
            state.openProjectFolder(entry)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: entry.isPinned ? "pin.fill" : "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(entry.isPinned ? Theme.accent : Theme.textTertiary)
                    .frame(width: 11)

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name)
                        // Pinned rows are always bright — a pin is a standing
                        // declaration that this folder matters, so it reads the
                        // same whether or not it is the folder in use. Recent
                        // rows dim to tertiary unless they are the open
                        // workspace, matching the workspaces above: one rule for
                        // "what is selected" across both lists.
                        .font(.system(size: 11))
                        .foregroundStyle(
                            entry.isPinned || isActive(entry)
                                ? Theme.textPrimary
                                : Theme.textTertiary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The full path, because two folders called `api` on
                    // different disks are the same name and the only way to tell
                    // them apart from a row is the path under it.
                    Text(abbreviate(entry.path))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 2)

                if !present {
                    Text("gone")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning)
                } else if isActive(entry) {
                    MXIconView(name: .check, size: 10, tint: Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovering ? Theme.surfaceElevated : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredPath = $0 ? entry.path : nil }
        // A folder that is not there is still listed — it may be on a volume
        // that is not mounted — but it cannot be clicked into, because clicking
        // would open a workspace pointing at nothing.
        .disabled(!present)
        .contextMenu {
            Button(entry.isPinned ? "Unpin" : "Pin") {
                state.togglePin(path: entry.path)
            }
            Button("Remove from this list") {
                state.forgetProjectFolder(path: entry.path)
            }
            Button("Reveal in Finder") {
                state.revealProjectFolder(entry)
            }
            .disabled(!present)
        }
        .help(present ? entry.path : "\(entry.path) — not found on disk")
    }

    /// The path with the home directory folded away.
    ///
    /// Every folder on this machine lives under the home directory, and
    /// printing it in full on every row leaves about half the width for the
    /// part that differs. `~` costs one column and says the same thing.
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
