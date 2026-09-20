import AppKit
import JXCodeCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            WorkspaceDetail()
        }
        // Follows the system appearance. `Theme` used to pin a single dark
        // palette and this line pinned the scheme to match it; now that the
        // palette carries a light and a dark set of stops, there is nothing to
        // pin — and pinning would deny a light-mode user the design they were
        // given.
        .background(Theme.surfaceDeepest)
        .sheet(isPresented: $state.promptForWorkspace) {
            NewWorkspaceSheet()
        }
        .sheet(isPresented: $state.showInspector) {
            InspectorSheet()
        }
        .sheet(isPresented: $state.showProviders) {
            ProvidersSheet()
        }
        .sheet(isPresented: $state.showModels) {
            ModelsSheet()
        }
        .sheet(isPresented: $state.showAdoptWorkspace) {
            AdoptWorkspaceSheet()
        }
        .sheet(isPresented: $state.showAddAgent) {
            AddAgentSheet()
        }
        .alert("JXCode", isPresented: bannerPresented) {
            Button("OK") { state.banner = nil }
        } message: {
            Text(state.banner ?? "")
        }
    }

    private var bannerPresented: Binding<Bool> {
        Binding(
            get: { state.banner != nil },
            set: { if !$0 { state.banner = nil } }
        )
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader()

            List(selection: $state.selectedWorkspaceID) {
                Section("Workspaces") {
                    ForEach(state.workspaces) { workspace in
                        WorkspaceRow(workspace: workspace)
                            .listRowBackground(
                                workspace.id == state.selectedWorkspaceID
                                    ? Theme.surfaceElevated : Color.clear
                            )
                            .tag(workspace.id)
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.selectFile(
                                        workspace.path,
                                        inFileViewerRootedAtPath: ""
                                    )
                                }
                                Divider()
                                Button("Forget workspace", role: .destructive) {
                                    state.deleteWorkspace(id: workspace.id)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().overlay(Theme.border)

            SharedSidebarSection()

            Divider().overlay(Theme.border)

            SandboxFooter()

            Divider().overlay(Theme.border)
        }
        .background(Theme.surface)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New workspace") { state.promptForWorkspace = true }
                    Button("Open existing folder…") { state.showAdoptWorkspace = true }
                    Divider()
                    Button("Refresh git status") { state.refreshGitStatuses() }
                        .disabled(state.isRefreshingGit)
                } label: {
                    MXIconView(name: .add, size: 13)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New or existing workspace")
            }
        }
    }
}

/// Top bar inside the sidebar: logo mark + product name, sitting on the
/// sidebar surface, matching the reference's title row.
struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.tilePurple)
                MXIconView(name: .package, size: 14, tint: Theme.ink(on: Theme.tilePurple))
            }
            .frame(width: 26, height: 26)

            Text("JXCode")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}


struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 9) {
            IconTile(
                icon: .folder,
                color: Theme.tile(for: workspace.path),
                size: 22
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(workspace.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                GitBadge(status: state.gitStatus(for: workspace))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

struct SandboxFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let status = state.sandboxStatus
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.healthy ? Theme.success : Theme.warning)
                    .frame(width: 7, height: 7)

                Text(status.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button {
                    state.refreshDoctor()
                } label: {
                    MXIconView(name: .doctor, size: 12, tint: Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Run sandbox doctor")
            }

            Text(state.sandbox.paths.display(state.sandbox.paths.envRoot))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(state.sandbox.paths.envRoot.path)

            HStack(spacing: 10) {
                Button("Import from host") {
                    state.importFromHost(dryRun: false)
                }
                Button("Inspect") {
                    state.showInspector = true
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))

            // Model routing status, so it is visible without opening the pane.
            Button {
                state.showProviders = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.routerRunning ? Theme.success : Theme.textTertiary)
                        .frame(width: 7, height: 7)
                    Text(routerSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Model routing")

            // The local model, on the same principle: if a multi-gigabyte model
            // is loaded, that should be visible without opening a pane.
            Button {
                state.showModels = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(localModelDotColor)
                        .frame(width: 7, height: 7)
                    Text(localModelSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Local models")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Says what the server is actually doing, not merely that it was started.
    ///
    /// "serving" used to be printed from a flag set once at launch, so a model
    /// that had died minutes ago still read as loaded. The health label is the
    /// polled truth.
    private var localModelSummary: String {
        guard state.isServing else { return "no local model loaded" }
        let name = state.servedModelName ?? "a model"
        let port = state.servedPort.map { ":\($0)" } ?? ""
        return "\(state.serverHealth.label) · \(name)\(port)"
    }

    private var localModelDotColor: Color {
        switch state.serverHealth {
        case .healthy:              return Theme.success
        case .unreachable, .exited: return Theme.danger
        case .idle, .loading:       return Theme.textTertiary
        }
    }

    private var routerSummary: String {
        if state.routerRunning, let model = state.selectedModel {
            return "routing · \(model)"
        }
        if let provider = state.selectedProvider {
            return "\(provider.name) · not routing"
        }
        return "no backend configured"
    }
}

// MARK: - Detail

struct WorkspaceDetail: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let workspace = state.selectedWorkspace {
            VStack(spacing: 0) {
                TabBar()
                Divider()

                ZStack {
                    if state.tabs.isEmpty {
                        AgentDashboard(workspace: workspace)
                    } else {
                        // Every tab stays in the hierarchy so switching does not
                        // tear down a running pty or reload a web panel.
                        ForEach(state.tabs) { tab in
                            tabContent(tab)
                                .opacity(tab.id == state.selectedTabID ? 1 : 0)
                                .allowsHitTesting(tab.id == state.selectedTabID)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(workspace.name)
            .navigationSubtitle(workspace.path)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        state.showProviders = true
                    } label: {
                        Label {
                            Text(state.routerRunning ? "Routing" : "Model routing")
                        } icon: {
                            MXIconView(
                                name: state.routerRunning ? .routing : .cpu,
                                size: 12
                            )
                        }
                    }
                    .help(state.routerRunning
                          ? "Agents are routing through \(state.router.baseURL)"
                          : "Register a backend and route every agent through it")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        state.showModels = true
                    } label: {
                        Label {
                            Text(state.isServing ? "Serving" : "Local models")
                        } icon: {
                            MXIconView(
                                name: state.isServing ? .play : .package,
                                size: 12
                            )
                        }
                    }
                    .help(state.isServing
                          ? "Serving \(state.servedModelName ?? "a model")"
                          : "Serve a GGUF file from this machine")
                }
            }
        } else {
            VStack(spacing: 8) {
                MXIconView(name: .layers, size: 30, tint: Theme.textTertiary)
                Text("No workspace selected")
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TabItem) -> some View {
        switch tab.kind {
        case .terminal(let controller):
            TerminalPane(controller: controller)
        case .web(let controller):
            WebPanel(controller: controller)
        case .shared:
            SharedPane()
        }
    }
}

// MARK: - Dashboard

/// What a workspace shows before it has any tabs: the agent launcher.
///
/// This is the app's front door, so it is laid out as a dashboard rather than
/// as a list — a hero that says where you are, a row of facts about the
/// sandbox, then every agent as a card. What it replaced was a bare vertical
/// list that answered "which agent" without first answering "what am I looking
/// at", and left the install state as a footnote on each row.
struct AgentDashboard: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    /// `adaptive` rather than a fixed column count, so the grid reflows on a
    /// window resize without a second layout to keep in sync.
    private let columns = [GridItem(.adaptive(minimum: 238, maximum: 340), spacing: 12)]

    private var agents: [AgentDefinition] { state.registry.agents }

    private var installedCount: Int {
        agents.filter { state.isInstalled(agentID: $0.id) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DashboardHero(workspace: workspace)
                facts

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Agents")

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(agents, id: \.id) { agent in
                            AgentCard(agent: agent)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Tools")

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(state.tools) { tool in
                            ToolCard(tool: tool)
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 30)
            .padding(.bottom, 44)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceDeepest)
    }

    /// The sandbox's state, in one row of chips.
    ///
    /// Read-only on purpose. Each of these answers a question that would
    /// otherwise mean opening a pane — how many agents are ready, how many
    /// workspaces exist, whether the isolation is intact, and whether anything
    /// is actually serving the agents a model.
    private var facts: some View {
        let status = state.sandboxStatus

        return HStack(spacing: 8) {
            DashboardStat(
                icon: .check,
                value: "\(installedCount) of \(agents.count)",
                label: "agents ready",
                tint: installedCount == agents.count ? Theme.success : Theme.warning
            )
            DashboardStat(
                icon: .folder,
                value: "\(state.workspaces.count)",
                label: state.workspaces.count == 1 ? "workspace" : "workspaces",
                tint: Theme.tileTeal
            )
            DashboardStat(
                icon: .shield,
                value: status.healthy ? "isolated" : "check",
                label: "sandbox",
                tint: status.healthy ? Theme.success : Theme.warning
            )
            DashboardStat(
                icon: .routing,
                value: state.routerRunning ? "routing" : "off",
                label: "model route",
                tint: state.routerRunning ? Theme.accent : Theme.textTertiary
            )
        }
    }
}

/// A small uppercase heading, so sections read as sections rather than as
/// another line of body text.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// The dashboard's opening block: where you are, and what to do.
private struct DashboardHero: View {
    let workspace: Workspace

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.tilePurple)
                MXIconView(name: .bolt, size: 23, tint: Theme.ink(on: Theme.tilePurple))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(workspace.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Start an agent below. Each one gets its own tab, "
                    + "isolated from your machine.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
    }
}

/// One fact about the sandbox, as a chip.
private struct DashboardStat: View {
    let icon: MXIconName
    let value: String
    let label: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 9) {
            MXIconView(name: icon, size: 14, tint: tint)

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

/// One agent in the launcher grid.
///
/// A whole card is a single target: clicking it installs the agent if it is
/// missing and then opens its tab, which is the same contract the old row had.
/// The difference is that the state is now legible before the click — the badge
/// says `ready`, `install`, `installing` or `retry` rather than leaving the user
/// to discover it by clicking.
private struct AgentCard: View {
    @EnvironmentObject private var state: AppState
    let agent: AgentDefinition

    @State private var isHovering = false

    private var isInstalling: Bool { state.installingAgentIDs.contains(agent.id) }
    private var failure: String? { state.installFailures[agent.id] }
    private var isInstalled: Bool { state.isInstalled(agentID: agent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                AgentIconTile(agentID: agent.id, size: 36)
                Spacer(minLength: 0)
                status
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(failure == nil ? Theme.textSecondary : Theme.warning)
                    .lineLimit(2)
                    // Without this a two-line tagline truncates to one line and
                    // the cards in a row stop matching heights.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Theme.surfaceElevated : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovering ? Theme.borderStrong : Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { state.openTab(agentID: agent.id) }
        .disabled(isInstalling)
        // The failure text carries the tail of npm's own output, so it belongs
        // in a tooltip rather than in the card.
        .help(failure ?? AgentPresentation.tagline(for: agent.id))
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var status: some View {
        if isInstalling {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: 9, height: 9)
                Text("installing")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.14)))
        } else if failure != nil {
            Badge(
                text: "retry",
                color: Theme.warning,
                background: Theme.warning.opacity(0.14)
            )
        } else if isInstalled {
            Badge(
                text: "ready",
                color: Theme.success,
                background: Theme.success.opacity(0.14)
            )
        } else {
            Badge(text: "install", color: Theme.textSecondary)
        }
    }

    /// While an install is running the card says what it is doing; on failure it
    /// says so instead of pretending the agent is ready.
    private var subtitle: String {
        if let progress = state.installProgress[agent.id] { return progress }
        if failure != nil { return "Install failed — click to try again" }
        return AgentPresentation.tagline(for: agent.id)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(isInstalled ? "Open" : "Install and open")
                    .font(.system(size: 11, weight: .medium))
                MXIconView(
                    name: isInstalled ? .arrowRight : .download,
                    size: 11,
                    tint: Theme.accent
                )
            }
            .foregroundStyle(Theme.accent)

            Spacer(minLength: 0)

            // Only the async agents have a second surface. Jules dispatches to
            // a cloud VM, so the dashboard is where the work is watched.
            if agent.webURL != nil {
                Button {
                    state.openWebPanel(agentID: agent.id)
                } label: {
                    Text("Dashboard")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Watch \(agent.name) in its web dashboard")
            }
        }
    }
}

/// A tool on the dashboard.
///
/// Shorter than an agent card, and deliberately so. An agent card has to answer
/// three questions — what the agent *is*, whether it is installed, and what
/// clicking will do about it. A tool is something the user already chose to
/// have, so this card answers one: can it run here yet, and if not, what would
/// make that true.
private struct ToolCard: View {
    @EnvironmentObject private var state: AppState
    let tool: ToolDefinition

    @State private var isHovering = false

    private var location: ToolLocator.Location? { state.location(of: tool) }
    private var isLinked: Bool { state.isToolLinked(tool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(
                    icon: AgentPresentation.icon(forTool: tool.id),
                    color: AgentPresentation.tint(forTool: tool.id),
                    size: 36
                )
                Spacer(minLength: 0)
                badge
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(location == nil ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(2)
                    // Without this a two-line subtitle truncates to one line and
                    // the cards in a row stop matching heights.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Theme.surfaceElevated : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovering ? Theme.borderStrong : Theme.border, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(tool.tagline)
    }

    @ViewBuilder
    private var badge: some View {
        if let location {
            switch location {
            case .sandbox:
                Badge(text: "ready", color: Theme.success,
                      background: Theme.success.opacity(0.14))
            case .host:
                Badge(text: "Mac only", color: Theme.warning,
                      background: Theme.warning.opacity(0.14))
            }
        } else {
            Badge(text: "not found", color: Theme.textSecondary)
        }
    }

    /// What is true, and then what to do about it — in that order, because the
    /// second half is only meaningful once the first is known.
    private var subtitle: String {
        guard let location else { return "Not on your Mac, or in the sandbox." }
        switch location {
        case .sandbox:
            return isLinked ? "Linked into the sandbox by JXCode." : tool.tagline
        case .host:
            return "Installed on your Mac, outside the sandbox."
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if location?.isInSandbox == true {
                Button {
                    state.launchTool(tool)
                } label: {
                    Text("Launch").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.primaryCompact)

                // Only offered for a link this app made. A tool the user
                // installed inside the sandbox themselves is not ours to remove.
                if isLinked {
                    Button {
                        state.unlinkTool(tool)
                    } label: {
                        Text("Remove from sandbox")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the link JXCode made. \(tool.name) stays on your Mac.")
                }
            } else if location != nil {
                Button {
                    state.linkTool(tool)
                } label: {
                    Text("Add to sandbox").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.primaryCompact)
                .help("Link \(tool.name) into the sandbox so every agent can run it")
            } else {
                Text("Install it, then reopen this tab.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)
        }
    }
}

/// Shared icon mapping, so the tab bar and the launcher agree.
///
/// This is the *glyph* for an agent, not its mark. The marks themselves come
/// from the icon files the user supplied and are drawn by `AgentIconTile`; this
/// table is what a tab chip uses at 10pt, where a full-colour logo would be
/// illegible. They are deliberately allowed to differ.
enum AgentPresentation {
    static func icon(for agentID: String) -> MXIconName {
        switch agentID {
        case "claude":   return .sparkle
        case "codex":    return .code
        case "gemini":   return .star
        case "opencode": return .terminal
        case "omp":      return .bolt
        case "jules":    return .cloud
        case "shell":    return .terminal
        default:         return .terminal
        }
    }

    /// Glyph for a tool.
    ///
    /// A separate table from the agents' on purpose: they are separate lists of
    /// things, and one shared table would let a tool pick up an agent's icon by
    /// coincidence of id — which is the kind of coupling that reads as a bug the
    /// first time someone adds a tool named `codex`.
    static func icon(forTool toolID: String) -> MXIconName {
        switch toolID {
        case "herdr": return .layers
        case "jcode": return .code
        default:      return .terminal
        }
    }

    /// Dot colour for a tool, drawn from the same six-colour ramp the workspaces
    /// use so the dashboard reads as one surface rather than two lists.
    static func tint(forTool toolID: String) -> Color {
        Theme.tile(for: "tool:\(toolID)")
    }

    /// One-line description for the action card. Kept short — these are not
    /// tooltips, they're the description that tells the user *what kind* of
    /// agent this is before they click.
    static func tagline(for agentID: String) -> String {
        switch agentID {
        case "claude":   return "Anthropic's coding agent"
        case "codex":    return "OpenAI's coding agent"
        case "gemini":   return "Google's CLI agent"
        case "opencode": return "Open-source terminal coding agent"
        // Not "Oh My Posh". That is a shell prompt theme engine, and a
        // different project entirely — the one thing this row must not do is
        // describe the agent as something it is not.
        case "omp":      return "Coding agent with the IDE wired in"
        case "jules":    return "Google's async coding agent"
        case "shell":    return "Plain zsh inside the sandbox"
        default:         return "Custom agent"
        }
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(state.tabs) { tab in
                        TabChip(tab: tab, isSelected: tab.id == state.selectedTabID) {
                            state.selectedTabID = tab.id
                        } onClose: {
                            state.closeTab(id: tab.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            AgentMenu()
        }
        .frame(height: 36)
        .background(Theme.surface)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

struct TabChip: View {
    @ObservedObject var tab: TabItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            MXIconView(
                name: tab.icon,
                size: 11,
                tint: isSelected ? Theme.accent : Theme.textTertiary
            )

            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(
                    tab.isRunning
                        ? (isSelected ? Theme.textPrimary : Theme.textSecondary)
                        : Theme.textTertiary
                )

            if isHovering {
                Button(action: onClose) {
                    MXIconView(name: .close, size: 9, tint: Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 190)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.surfaceElevated : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Theme.borderStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Agent launcher

struct AgentMenu: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Menu {
            ForEach(state.registry.agents, id: \.id) { agent in
                AgentMenuItem(agent: agent)
            }
            Divider()
            Button("Add an agent…") { state.showAddAgent = true }
        } label: {
            MXIconView(name: .add, size: 13)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.trailing, 10)
        .help("New tab")
    }
}

/// One row of the launcher.
///
/// Extracted from `AgentMenu` on purpose: nesting `Menu` and `Button` builders
/// inside a `ForEach` closure inside another `Menu` closure overwhelms SwiftUI's
/// result-builder inference, and the errors it emits point at `ForEach` rather
/// than at the real problem. A named view gives the type checker a boundary.
private struct AgentMenuItem: View {
    @EnvironmentObject private var state: AppState
    let agent: AgentDefinition

    var body: some View {
        if agent.webURL != nil {
            // Async agents get both surfaces: the CLI dispatches the work, the
            // dashboard is where you watch it happen.
            Menu(agent.name) {
                Button("Terminal") { state.openTab(agentID: agent.id) }
                Button("Embedded dashboard") { state.openWebPanel(agentID: agent.id) }
            }
        } else {
            Button(title) { state.openTab(agentID: agent.id) }
                .disabled(state.installingAgentIDs.contains(agent.id))
        }
    }

    /// Uses the cached set rather than resolving per row: a `Menu` body is
    /// rebuilt on every state change, and each lookup walks the sandbox `PATH`.
    private var title: String {
        if state.installingAgentIDs.contains(agent.id) {
            return "\(agent.name)  ·  installing…"
        }
        return state.isInstalled(agentID: agent.id) ? agent.name : "\(agent.name)  ·  not installed"
    }
}

// MARK: - Sheets

struct NewWorkspaceSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New workspace")
                .font(.system(size: 15, weight: .medium))

            TextField("Name", text: $state.newWorkspaceName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(create)

            Text("A directory is created inside the sandbox.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    state.newWorkspaceName = ""
                    state.promptForWorkspace = false
                }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func create() {
        state.createWorkspace(named: state.newWorkspaceName)
        state.newWorkspaceName = ""
        state.promptForWorkspace = false
    }
}

struct InspectorSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sandbox inspector")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button {
                    state.refreshDoctor()
                } label: {
                    Label {
                        Text("Re-run")
                    } icon: {
                        MXIconName.refresh.view(size: 11)
                    }
                }
                .font(.system(size: 11))
                Button("Done") { state.showInspector = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary = state.importSummary {
                        section("Import") {
                            Text(summary)
                        }
                    }

                    section("Doctor") {
                        Text(state.doctorReport?.rendered(verbose: true) ?? "Running…")
                    }

                    section("Environment") {
                        Text(state.sandbox.environment.report(workspace: state.selectedWorkspace))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 620)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
