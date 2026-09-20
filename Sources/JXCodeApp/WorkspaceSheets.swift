import AppKit
import JXCodeCore
import SwiftUI

// MARK: - Adopting an existing directory

/// Point a workspace at a directory that already exists.
///
/// The isolation this app provides is about the *toolchain*, not about hiding
/// your code, so opening a real repository is the ordinary case rather than an
/// escape hatch. Nothing is copied, moved, or written — the workspace is a
/// pointer, and the agents that run in it still live inside the sandbox.
struct AdoptWorkspaceSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open an existing folder")
                    .font(.system(size: 15, weight: .medium))
                Text("Your files stay where they are. Only the toolchain is sandboxed.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                TextField("Path", text: $state.adoptPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(state.adoptWorkspace)
                Button("Choose…", action: choose)
            }

            TextField("Name (optional)", text: $state.adoptName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Text("Left blank, the folder's own name is used.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    state.adoptPath = ""
                    state.adoptName = ""
                    state.showAdoptWorkspace = false
                }
                Button("Open", action: state.adoptWorkspace)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.adoptPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        // Deliberately not restricted to the sandbox: the whole point is to
        // work on code that lives outside it.
        if panel.runModal() == .OK, let url = panel.url {
            state.adoptPath = url.path
            if state.adoptName.isEmpty {
                state.adoptName = url.lastPathComponent
            }
        }
    }
}

// MARK: - Registering a custom agent

/// Add a CLI the built-in list does not know about.
///
/// The registry has always loaded custom agents from `agents.json`; nothing
/// exposed it, so adding one meant hand-editing JSON. The app launches
/// arbitrary CLIs by design, so its list should not be a closed set.
struct AddAgentSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an agent")
                    .font(.system(size: 15, weight: .medium))
                Text("It runs inside the sandbox, with the private HOME and PATH.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            field("Name", text: $state.newAgentName, placeholder: "Aider")
            field("Command", text: $state.newAgentCommand, placeholder: "aider")
            field("Arguments", text: $state.newAgentArguments, placeholder: "--no-auto-commits")
            field("Install command", text: $state.newAgentInstallCommand, placeholder: "pip install aider-chat")

            Text("Arguments are split on spaces. The install command is typed into a sandboxed "
                + "shell the first time you launch an agent that is not on PATH yet.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") {
                    state.showAddAgent = false
                }
                Button("Add", action: state.addCustomAgent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.newAgentName.trimmingCharacters(in: .whitespaces).isEmpty
                              || state.newAgentCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Git badge

/// A compact git indicator, for a workspace row.
///
/// Shows the branch and a dirty marker rather than a count, because at a glance
/// the question is "is this clean and on what branch", not "how many files".
struct GitBadge: View {
    let status: GitStatus?

    var body: some View {
        if let status, status.isRepository, status.error == nil {
            HStack(spacing: 4) {
                MXIconView(name: .routing, size: 9)
                Text(status.branch ?? "detached")
                    .font(.system(size: 10, design: .monospaced))
                if status.isDirty {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 5, height: 5)
                }
                if status.ahead > 0 || status.behind > 0 {
                    Text(divergence(status))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
    }

    private func divergence(_ status: GitStatus) -> String {
        var parts: [String] = []
        if status.ahead > 0 { parts.append("+\(status.ahead)") }
        if status.behind > 0 { parts.append("-\(status.behind)") }
        return parts.joined(separator: " ")
    }
}
