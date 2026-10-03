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
/// Two ways in, because they answer different questions. The catalog is for an
/// agent someone has heard of and expects JXCode to know — the built-in list is
/// five CLIs, and "it is not in the list" read as "it is not supported". The form
/// is for everything else, and has always been the general answer: the app
/// launches arbitrary CLIs by design, so its list should not be a closed set.
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

            if !state.suggestedAgents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From the catalog")
                        .font(.system(size: 12, weight: .semibold))

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.suggestedAgents, id: \.id) { agent in
                                SuggestedAgentRow(agent: agent)
                                if agent.id != state.suggestedAgents.last?.id {
                                    Divider().overlay(Theme.border)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1)
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Or add your own")
                    .font(.system(size: 12, weight: .semibold))

                field("Name", text: $state.newAgentName, placeholder: "Aider")
                field("Command", text: $state.newAgentCommand, placeholder: "aider")
                field("Arguments", text: $state.newAgentArguments, placeholder: "--no-auto-commits")
                field("Install command", text: $state.newAgentInstallCommand, placeholder: "pip install aider-chat")
            }

            Text("Arguments are split on spaces. The install command runs inside the sandbox the first "
                + "time you launch an agent that is not on PATH yet.")
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
        .frame(width: 520)
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

/// One catalog entry, with the install command it would run.
private struct SuggestedAgentRow: View {
    @EnvironmentObject private var state: AppState
    let agent: AgentDefinition

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
                if let tagline = agent.tagline {
                    Text(tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let install = agent.installCommand {
                    Text(install)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button("Add") {
                state.addSuggestedAgent(agent)
                state.showAddAgent = false
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - Registering a tool

/// Add something you already run, so the dashboard has a button for it.
///
/// The same two ways in as the agent sheet, and for the same reason. The
/// difference is what happens next: an agent is *installed* inside the sandbox,
/// while a tool is *linked* into it — so a tool that is already on the Mac is
/// usable in one more click, and the catalog's install commands are the only
/// thing the card has to offer for one that is not.
struct AddToolSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a tool")
                    .font(.system(size: 15, weight: .medium))
                Text("Something you already run. Once it is on the dashboard, one click links it "
                    + "into the sandbox so every agent can use it too.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.suggestedTools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From the catalog")
                        .font(.system(size: 12, weight: .semibold))

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.suggestedTools, id: \.id) { tool in
                                SuggestedToolRow(tool: tool)
                                if tool.id != state.suggestedTools.last?.id {
                                    Divider().overlay(Theme.border)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1)
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Or add your own")
                    .font(.system(size: 12, weight: .semibold))

                field("Name", text: $state.newToolName, placeholder: "My CLI")
                field("Command", text: $state.newToolBinary, placeholder: "mycli")
                field("Arguments", text: $state.newToolArguments, placeholder: "--profile work")
                field("Description", text: $state.newToolTagline, placeholder: "What it is for")
                field("Install command", text: $state.newToolInstallCommand, placeholder: "brew install mycli")
            }

            Text("The command is a bare name, resolved on the sandbox PATH. A name containing a slash "
                + "would be read as a path and would bypass the sandbox.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { state.showAddTool = false }
                Button("Add", action: state.addCustomTool)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.newToolName.trimmingCharacters(in: .whitespaces).isEmpty
                              || state.newToolBinary.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
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

/// One catalog tool, with where it is right now.
private struct SuggestedToolRow: View {
    @EnvironmentObject private var state: AppState
    let tool: ToolDefinition

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .medium))
                    // The one fact that decides whether Add is useful: a tool
                    // that is already on the Mac is one click from being usable
                    // in the sandbox, and one that is not needs its install
                    // command run first.
                    if let location = state.location(of: tool) {
                        Text(location.isInSandbox ? "ready" : "on your Mac")
                            .font(.system(size: 10))
                            .foregroundStyle(location.isInSandbox ? Theme.success : Theme.warning)
                    } else {
                        Text("not installed")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(tool.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                if let install = tool.installCommand {
                    Text(install)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button("Add") {
                state.addTool(tool)
                state.showAddTool = false
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
