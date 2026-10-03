import AppKit
import JXCodeCore
import SwiftUI

/// The mainframe: sidebar on the left, everything else to its right.
///
/// This is the kooky-shaped mainframe, and the shape is the point. The previous
/// layout was a `NavigationSplitView` whose detail column held a tab bar, which
/// meant the tab strip lived *inside* a pane that could collapse out from under
/// it. Now the sidebar and the main column are siblings of one `HStack`, so the
/// whole right side — top bar, tab strip, content, status bar — is the unit the
/// sidebar collapses against, exactly like a terminal app: workspaces down the
/// left edge, tabs across the top, live state along the bottom.
struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            // The margin. Whatever the mainframe does, this is what shows at
            // the window's edges and in its rounded corners — a frame of the
            // deepest surface, so the chrome reads as a panel laid on a
            // background rather than a print cut to the paper's edge.
            Theme.surfaceDeepest

            HStack(spacing: 0) {
                if !state.isSidebarCollapsed {
                    SidebarView()
                        .transition(.move(edge: .leading))
                }
                MainColumn()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .animation(.easeOut(duration: 0.16), value: state.isSidebarCollapsed)
        // Follows the system appearance. The palette carries a light and a dark
        // set of stops, so there is nothing to pin — and pinning would deny a
        // light-mode user the design they were given.
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
        .sheet(isPresented: $state.showPrimaryPicker) {
            PrimaryPickerSheet()
        }
        .sheet(isPresented: $state.showSandboxLocation) {
            SandboxLocationSheet()
        }
        .sheet(isPresented: $state.showAddTool) {
            AddToolSheet()
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

/// Workspaces, the shared collection, and the three live services — in a single
/// quiet column.
///
/// The three services (sandbox, router, local model) used to be a footer of
/// buttons and link-styled rows; they are status rows now, because that is what
/// they are. Everything a click used to reveal through a sheet is still one
/// click away — the row *is* the button — but the column reads as state first
/// and actions second, which is the order a workspace manager should read in.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("WORKSPACES") { sidebarActions }

                    ForEach(state.workspaces) { workspace in
                        WorkspaceRow(workspace: workspace)
                    }

                    if state.workspaces.isEmpty {
                        Text("No workspaces yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 4)
                    }

                    // Folders worked in and folders pinned, above the saved
                    // workspaces. They lead because they are what the person
                    // came back for; the workspaces below are the configured
                    // set, and are usually the same folders once more.
                    ProjectFoldersSection()
                        .padding(.top, 6)

                    SharedSidebarSection()
                        .padding(.top, 6)

                    // The three services, as state rows.
                    VStack(spacing: 2) {
                        sectionLabel("SERVICES")
                        serviceRows
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .padding(.top, 2)
            }

            SidebarFooter()
        }
        .frame(width: 244)
        .background(Theme.surfaceDeepest)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1),
            alignment: .trailing
        )
    }

    /// The header's two quiet actions, exposed where the section label can hold
    /// them: a new workspace and the adopt-an-existing-folder flow.
    private var sidebarActions: some View {
        HStack(spacing: 2) {
            TopBarButton(icon: .add, help: "New workspace") {
                state.promptForWorkspace = true
            }
            TopBarButton(icon: .folderAdd, help: "Open an existing folder…") {
                state.showAdoptWorkspace = true
            }
        }
    }

    @ViewBuilder
    private var serviceRows: some View {
        let status = state.sandboxStatus
        ServiceRow(
            icon: .shield,
            color: status.healthy ? Theme.success : Theme.warning,
            label: "Sandbox",
            detail: status.label
        ) {
            // The row still opens the inspector. The location is a separate,
            // quieter door: it changes where everything on this Mac is written,
            // which is a different kind of question from "is the isolation
            // intact", and putting it behind the same click would bury it.
            state.showSandboxLocation = true
        }
        ServiceRow(
            icon: .routing,
            color: state.routerRunning ? Theme.accent : Theme.textTertiary,
            label: "Router",
            detail: routerDetail
        ) {
            state.showProviders = true
        }
        ServiceRow(
            icon: .cpu,
            color: localModelColor,
            label: "Local model",
            detail: localModelDetail
        ) {
            state.showModels = true
        }
    }

    private var routerDetail: String {
        if state.routerRunning, let model = state.selectedModel {
            return model
        }
        if state.routerRunning { return "listening" }
        if let provider = state.selectedProvider { return provider.name }
        return "off"
    }

    private var localModelDetail: String {
        guard state.isServing else { return "not loaded" }
        let name = state.servedModelName ?? "model"
        let port = state.servedPort.map { ":\($0)" } ?? ""
        return "\(name)\(port)"
    }

    private var localModelColor: Color {
        switch state.serverHealth {
        case .healthy:      return Theme.success
        case .unreachable, .exited: return Theme.danger
        case .idle, .loading:       return Theme.textTertiary
        }
    }

    private func sectionLabel(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }

    private func sectionLabel(_ text: String) -> some View {
        sectionLabel(text) { EmptyView() }
    }
}

/// The sidebar's title row: the mark, the name, and the collapse toggle.
struct SidebarHeader: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            // White mark on transparent, straight from the artwork. No tile
            // and no rounded-rect glow — a glow modifier would paint a lit
            // rectangle *behind* a mark with no opaque backing, which reads
            // as a smudged pill rather than light around a shape.
            AppLogoView(size: 26)

            Text("JXCode")
                // Regular, like every label in the sidebar. The name is
                // identified by the bolt beside it, not by being the boldest
                // thing in the column — bold here would make the app's own name
                // compete with the section headings, which are the only labels
                // that are meant to stand out.
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            TopBarButton(icon: .layers, help: "Toggle sidebar (⌘B)") {
                withAnimation(.easeOut(duration: 0.16)) {
                    state.isSidebarCollapsed = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// One workspace in the sidebar: identity dot, name, git state.
///
/// kooky colours its workspace rows with a left stripe; here the stripe is a
/// dot, because the rows also carry a git readout and a stripe behind that text
/// fought it. The colour is still deterministic per path — `Theme.tile(for:)` —
/// so the eye learns where a workspace lives.
struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    @State private var isHovering = false

    private var isSelected: Bool { workspace.id == state.selectedWorkspaceID }

    var body: some View {
        Button {
            state.selectedWorkspaceID = workspace.id
        } label: {
            HStack(spacing: 9) {
                // The per-workspace colour dot is gone.
                //
                // It was `Theme.tile(for: workspace.path)` — a hue derived by
                // hashing the path, so every workspace got a different colour and
                // no two rows in the sidebar ever matched. Its stated purpose was
                // to help the eye find a workspace again, and it did the opposite:
                // a column of unrelated colours is the loudest thing in a sidebar
                // whose whole point is to be quiet, and it competed with the one
                // signal that carries real meaning — which row is the one you are
                // working in, now shown by the label's brightness alone.
                //
                // The row's own hover and selected fills still mark position, and
                // `GitBadge` still carries the git state, so nothing was lost but
                // the decoration.
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        // Regular, always. The sidebar's only emphasis is colour:
                        // the workspace you are working in is bright white and
                        // everything else is dimmed. Weight is not used to mark
                        // the active row, because a label that changes weight
                        // makes the column shimmer as the selection moves, and
                        // only the section headings above are meant to be bold.
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1)

                    GitBadge(status: state.gitStatus(for: workspace))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
                    .padding(.horizontal, 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Theme.borderStrong : Color.clear, lineWidth: 1)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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

    private var rowFill: Color {
        if isSelected { return Theme.surfaceElevated }
        if isHovering { return Theme.surfaceElevated.opacity(0.55) }
        return Color.clear
    }
}

/// One live service row. The whole row is the button into its pane.
private struct ServiceRow: View {
    let icon: MXIconName
    let color: Color
    let label: String
    let detail: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                MXIconView(name: icon, size: 12, tint: color)
                    .frame(width: 15)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 4)

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Theme.surfaceElevated.opacity(0.55) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The bottom of the sidebar: where the sandbox actually is.
///
/// The old footer carried an import button, an inspect button and two pseudo
/// rows for routing and models. All three jobs moved up into the service rows,
/// so what remains is the one fact that has no pane: the sandbox root on disk.
struct SidebarFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(state.sandbox.paths.display(state.sandbox.paths.envRoot))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(state.sandbox.paths.envRoot.path)

            Button {
                state.importFromHost(dryRun: false)
            } label: {
                HStack(spacing: 5) {
                    MXIconView(name: .download, size: 10, tint: Theme.textTertiary)
                    Text("Import from host")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - Main column

/// Everything right of the sidebar: top bar, tab strip, the content, the status
/// bar — in that order, top to bottom, like the terminal apps this shape comes
/// from.
struct MainColumn: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TabStrip()

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            content

            if state.isStatusBarVisible {
                StatusBar()
            }
        }
        .background(Theme.surface)
    }

    @ViewBuilder
    private var content: some View {
        if let workspace = state.selectedWorkspace {
            ZStack {
                if state.showDashboard || state.tabs.isEmpty {
                    WorkspaceLanding(workspace: workspace)
                } else {
                    // Every tab stays in the hierarchy so switching does not
                    // tear down a running pty or reload a web panel.
                    ForEach(state.tabs) { tab in
                        TabPane(tab: tab)
                            .opacity(tab.id == state.selectedTabID ? 1 : 0)
                            .allowsHitTesting(tab.id == state.selectedTabID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceDeepest)
            .navigationTitle(workspace.name)
        } else {
            NoWorkspaceView()
        }
    }
}

/// One tab's pane, plus the focus ring the selected pane gets.
///
/// The glow is the kooky move: exactly one pane in the window reads as lit. It
/// is drawn only for a *running* terminal — a dead pane is not the focused
/// thing, its exit is, and the tab dot says that instead.
private struct TabPane: View {
    @EnvironmentObject private var state: AppState
    let tab: TabItem

    private var isSelected: Bool { tab.id == state.selectedTabID }

    var body: some View {
        paneContent
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected && isLive
                            ? Theme.accent.opacity(0.55)
                            : Theme.border,
                        lineWidth: 1
                    )
            )
            .glow(Theme.accent, radius: 14, intensity: isSelected && isLive ? 0.45 : 0)
            .padding(.top, 8)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }

    private var isLive: Bool {
        guard case .terminal(let controller) = tab.kind else { return false }
        return controller.isRunning
    }

    @ViewBuilder
    private var paneContent: some View {
        switch tab.kind {
        case .terminal(let controller):
            TerminalPane(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .web(let controller):
            WebPanel(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .shared:
            SharedPane()
        }
    }
}

/// What the main column shows with no workspace selected.
private struct NoWorkspaceView: View {
    var body: some View {
        VStack(spacing: 10) {
            MXIconView(name: .folder, size: 28, tint: Theme.textTertiary)
            Text("No workspace selected")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuroraBackdrop())
    }
}

// MARK: - Top bar

/// Breadcrumb on the left, tool toggles on the right.
///
/// The routing and model buttons keep their previous meanings (open the pane)
/// but render as quiet chrome rather than toolbar buttons with labels — the
/// state they carry is already visible in the sidebar's service rows and the
/// status bar, so the top bar is navigation, not telemetry.
struct TopBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if state.isSidebarCollapsed {
                TopBarButton(icon: .layers, help: "Show sidebar (⌘B)") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        state.isSidebarCollapsed = false
                    }
                }
            }

            breadcrumb
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // Back to the dashboard. The landing is a state, not a tab, so
            // this is the only way back once a tab is open — and the tabs keep
            // running behind it.
            if !state.showDashboard {
                TopBarButton(
                    icon: .dashboard,
                    isActive: true,
                    help: "Back to the dashboard (tabs keep running)"
                ) {
                    state.showDashboardTab()
                }
            }

            TopBarButton(
                icon: .add,
                help: "New tab"
            ) {
                state.openShellTab()
            }

            // YOLO: one switch, every agent. Lit while on; the tooltip names
            // the flags the next launch will receive, because "YOLO" alone
            // says nothing about what will actually be skipped.
            TopBarButton(
                icon: .bolt,
                isActive: state.isYOLOEnabled,
                help: state.isYOLOEnabled
                    ? "YOLO is ON — next launches skip permission prompts "
                        + "(\(state.yoloArguments.joined(separator: " "))). Click to turn off."
                    : "YOLO mode — launch every agent with approval prompts skipped"
            ) {
                state.isYOLOEnabled.toggle()
            }

            TopBarButton(
                icon: .routing,
                isActive: state.routerRunning,
                help: state.routerRunning
                    ? "Routing through \(state.router.baseURL)"
                    : "Model routing"
            ) {
                state.showProviders = true
            }

            TopBarButton(
                icon: .cpu,
                isActive: state.isServing,
                help: state.isServing
                    ? "Serving \(state.servedModelName ?? "a model")"
                    : "Local models"
            ) {
                state.showModels = true
            }

            TopBarButton(icon: .doctor, help: "Run sandbox doctor") {
                state.refreshDoctor()
                state.showInspector = true
            }

            TopBarButton(icon: .search, help: "Toggle status bar") {
                state.isStatusBarVisible.toggle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if let workspace = state.selectedWorkspace {
            HStack(spacing: 6) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                if let tab = state.selectedTab {
                    Text("/")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Text(tab.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } else {
            Text("JXCode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Tab strip

/// The tab strip, kooky-style: an inline strip with a status dot per tab and a
/// close affordance on hover. Sits under the top bar rather than inside it, so
/// a long tab list scrolls without pushing the tools off-screen.
struct TabStrip: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(state.tabs) { tab in
                        TabChip(tab: tab, isSelected: !state.showDashboard && tab.id == state.selectedTabID) {
                            state.selectTab(id: tab.id)
                        } onClose: {
                            state.closeTab(id: tab.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            AgentMenu()
        }
        .background(Theme.surface)
    }
}

struct TabChip: View {
    @ObservedObject var tab: TabItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            // The kooky dot: running is the glow, stopped is the warning
            // amber — "needs you" — and a shared pane carries no dot at all.
            if !tab.isShared {
                Circle()
                    .fill(tab.isRunning ? Theme.accent : Theme.sunlit)
                    .frame(width: 7, height: 7)
            }

            MXIconView(
                name: tab.icon,
                size: 11,
                tint: isSelected ? Theme.accent : Theme.textTertiary
            )

            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(
                    isSelected ? Theme.textPrimary
                        : tab.isRunning ? Theme.textSecondary
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Theme.borderStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.isRunning ? "Running" : "Exited — the dot is amber")
    }

    private var chipFill: Color {
        if isSelected { return Theme.surfaceElevated }
        if isHovering { return Theme.surfaceElevated.opacity(0.55) }
        return Color.clear
    }
}

// MARK: - Agent launcher

/// The + menu: every agent, one click each.
///
/// Extracted rows exist on purpose: nesting `Menu` and `Button` builders inside
/// a `ForEach` closure inside another `Menu` closure overwhelms SwiftUI's
/// result-builder inference, and the errors it emits point at `ForEach` rather
/// than at the real problem. A named view gives the type checker a boundary.
struct AgentMenu: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Menu {
            ForEach(state.registry.agents, id: \.id) { agent in
                AgentMenuItem(agent: agent)
            }
            Divider()
            Button("Add an agent…") { state.showAddAgent = true }
            Button("Add a tool…") { state.showAddTool = true }
        } label: {
            MXIconView(name: .add, size: 13)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.trailing, 10)
        .help("New agent tab")
    }
}

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

// MARK: - Status bar

/// The live state of the selected workspace, along the bottom edge.
///
/// Pills rather than a footer of buttons: each is a readout that opens the pane
/// that owns it. The git half is only shown for a repository, and the path is
/// the only thing on the right — the left side is state, the right is identity.
struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            sandboxPill
            routerPill
            modelPill
            gitPill

            Spacer(minLength: 8)

            if let workspace = state.selectedWorkspace {
                Text(workspace.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspace.path)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    private var sandboxPill: some View {
        let status = state.sandboxStatus
        return StatusPill(
            color: status.healthy ? Theme.success : Theme.warning,
            label: "sandbox",
            detail: status.label,
            help: "Sandbox isolation — click to inspect"
        ) {
            state.showInspector = true
        }
    }

    private var routerPill: some View {
        StatusPill(
            color: state.routerRunning ? Theme.accent : Theme.textTertiary,
            label: "router",
            detail: routerDetail,
            help: "Model routing — click to configure"
        ) {
            state.showProviders = true
        }
    }

    private var modelPill: some View {
        StatusPill(
            color: modelColor,
            label: "model",
            detail: modelDetail,
            help: "Local GGUF serving — click to configure"
        ) {
            state.showModels = true
        }
    }

    @ViewBuilder
    private var gitPill: some View {
        if let status = state.selectedWorkspace.flatMap({ state.gitStatus(for: $0) }),
           status.isRepository, status.error == nil {
            StatusPill(
                color: status.isDirty ? Theme.sunlit : Theme.textTertiary,
                label: status.branch ?? "detached",
                detail: divergence(status),
                help: "Git state of the selected workspace"
            ) {
                state.refreshGitStatuses()
            }
        }
    }

    private var routerDetail: String {
        if state.routerRunning, let model = state.selectedModel { return model }
        if state.routerRunning { return "listening" }
        return "off"
    }

    private var modelDetail: String {
        guard state.isServing else { return "not loaded" }
        return "\(state.serverHealth.label)"
    }

    private var modelColor: Color {
        switch state.serverHealth {
        case .healthy:      return Theme.success
        case .unreachable, .exited: return Theme.danger
        case .idle, .loading:       return Theme.textTertiary
        }
    }

    private func divergence(_ status: GitStatus) -> String {
        var parts: [String] = []
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Landing (the dashboard)

/// What a workspace shows before it has any tabs.
///
/// The hero sits on the aurora — the illustration's horizon redrawn behind it —
/// then the facts row, then the two grids. It is still a dashboard rather than a
/// list: the front door should say where you are and what the click will do
/// before it is clicked.
struct WorkspaceLanding: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    /// `adaptive` rather than a fixed column count, so the grid reflows on a
    /// window resize without a second layout to keep in sync.
    ///
    /// The band starts at 196 rather than the old 238. That floor was set when a
    /// card had a 36pt icon on its own line and needed the width for it; with
    /// the icon beside the text, 196 is still wide enough for a name and a
    /// two-line tagline, and it fits three cards across in the window this app
    /// actually opens at instead of two.
    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 320), spacing: 12)]

    private var agents: [AgentDefinition] { state.registry.agents }

    private var installedCount: Int {
        agents.filter { state.isInstalled(agentID: $0.id) }.count
    }

    /// The count line beside the Agents heading.
    ///
    /// Names the primary when there is one. An agent that is in charge is a
    /// different thing from an agent that merely exists, and burying that in a
    /// per-card badge means the dashboard as a whole never says who is running
    /// the session — which is the one fact this screen is now about.
    private var agentsSectionDetail: String {
        guard let primary = state.primary else {
            return "\(agents.count) offered · none in charge"
        }
        return "\(agents.count) offered · \(primary.agentName) in charge"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DashboardHero(workspace: workspace)
                facts

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(
                        "Agents",
                        detail: agentsSectionDetail,
                        action: ("Primary…", { state.showPrimaryPicker = true })
                    )

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(agents, id: \.id) { agent in
                            AgentCard(agent: agent)
                        }

                        // The list is not a closed set — the app launches
                        // arbitrary CLIs — but until this tile existed the only
                        // way to add one was to hand-edit `agents.json`. The
                        // tile is the affordance; the sheet behind it offers the
                        // catalog and a form.
                        AddTile(
                            title: "Add an agent",
                            detail: "Any CLI, run inside the sandbox"
                        ) {
                            state.showAddAgent = true
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(
                        "Tools",
                        detail: "\(state.tools.count) offered",
                        action: ("Add tool…", { state.showAddTool = true })
                    )

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(state.tools) { tool in
                            ToolCard(tool: tool)
                        }

                        AddTile(
                            title: "Add a tool",
                            detail: "Something you already run — Hermes, Aider, Goose…"
                        ) {
                            state.showAddTool = true
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
        .background(
            ZStack {
                Theme.surfaceDeepest
                AuroraBackdrop()
            }
        )
    }

    /// A section heading, its count, and the one action that belongs to it.
    ///
    /// The action lives next to the heading rather than at the end of the grid
    /// so that it is in the same place whether the list is empty or full — an
    /// "add" tile that drifts to a new column as the grid grows is one nobody
    /// can find twice.
    private func sectionHeader(
        _ text: String,
        detail: String,
        action: (String, () -> Void)
    ) -> some View {
        HStack(spacing: 8) {
            SectionLabel(text)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button(action.0, action: action.1)
                .controlSize(.small)
        }
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
                tint: installedCount == agents.count ? Theme.success : Theme.sunlit
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
                tint: status.healthy ? Theme.success : Theme.sunlit
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

/// The landing's opening block: where you are, and what to do.
private struct DashboardHero: View {
    let workspace: Workspace

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppLogoView(size: 48)

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

/// The card at the end of a dashboard grid that adds another one.
///
/// Dashed rather than filled, and deliberately not a card of the same weight as
/// the ones beside it: it is an invitation, and an invitation that looks like an
/// installed thing is one people try to click twice.
private struct AddTile: View {
    let title: String
    let detail: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    MXIconView(
                        name: .add,
                        size: 14,
                        tint: isHovering ? Theme.accent : Theme.textSecondary
                    )
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHovering ? Theme.accent : Theme.textSecondary)
                    Spacer(minLength: 0)
                }

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(11)
            // No height floor, to match the cards beside it. A `minHeight` here
            // would make the "+ Add an agent" tile taller than every agent card
            // in the same row, which reads as the empty tile being the important
            // one. Rows in a `LazyVGrid` size to their tallest child, so the
            // cards set the height and this tile fills it.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Theme.surfaceElevated : Theme.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isHovering ? Theme.accent.opacity(0.55) : Theme.borderStrong,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// One agent in the launcher grid.
///
/// A whole card is a single target: clicking it installs the agent if it is
/// missing and then opens its tab, which is the same contract the old row had.
/// The difference is that the state is now legible before the click — the badge
/// says `ready`, `install`, `installing` or `retry` rather than leaving the user
/// to discover it by clicking.
///
/// Laid out as **icon left, text right**, and no taller than its content.
///
/// It used to be a column: a 36pt icon on its own row, then the name, then a
/// two-line tagline, then a `Spacer`, then the footer — pinned open by
/// `minHeight: 142`. That height was not a design decision, it was the
/// consequence of stacking five things and then forcing the card to 142pt so
/// the icons lined up. The result was a grid where every card was ~40pt taller
/// than anything in it, and with nine agents the launcher pushed the Tools
/// section below the fold.
///
/// Side by side, the icon and the name share a line, the tagline goes under the
/// name where it has the full column width to wrap into, and the card is as
/// tall as its text. `minHeight` is gone rather than lowered: a floor would
/// reintroduce the same empty band at a smaller size, and the density rule the
/// design template sets is that no card reserves height it does not use.
private struct AgentCard: View {
    @EnvironmentObject private var state: AppState
    let agent: AgentDefinition

    @State private var isHovering = false

    private var isInstalling: Bool { state.installingAgentIDs.contains(agent.id) }
    private var failure: String? { state.installFailures[agent.id] }
    private var isInstalled: Bool { state.isInstalled(agentID: agent.id) }
    private var isPrimary: Bool { state.isPrimary(agentID: agent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AgentIconTile(agentID: agent.id, size: 30)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)

                        status
                    }

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(failure == nil ? Theme.textSecondary : Theme.warning)
                        .lineLimit(2)
                        // The tagline needs to be allowed to grow: without this a
                        // two-line description truncates to one and the row
                        // collapses, which is how a card ends up clipping its own
                        // text in the middle of the grid.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            footer
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .help(failure ?? AgentPresentation.tagline(for: agent))
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
            .background(Capsule().fill(Theme.glow))
        } else if failure != nil {
            Badge(
                text: "retry",
                color: Theme.warning,
                background: Theme.warning.opacity(0.14)
            )
        } else if isPrimary {
            // Outranks "ready" deliberately. An agent that is both installed and
            // in charge is still in charge, and a card that said only "ready"
            // would leave the dashboard unable to answer who is running.
            Badge(
                text: "primary",
                color: Theme.accent,
                background: Theme.accent.opacity(0.16)
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
        return AgentPresentation.tagline(for: agent)
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

            // Only for agents the user added. A built-in is not removable —
            // `saveCustom()` persists only the non-built-in entries, so deleting
            // one would appear to work and then come back on the next launch.
            if state.registry.isCustom(id: agent.id) {
                Button {
                    state.removeAgent(id: agent.id)
                } label: {
                    MXIconView(name: .trash, size: 11, tint: Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(agent.name) from the dashboard")
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

    /// Asked once per draw, then handed to everything below.
    ///
    /// These were computed properties, and the card read `location` seven
    /// times across `badge`, `subtitle` and `footer`. Every read rebuilt the
    /// sandbox environment — a fresh dictionary of forty-plus entries — and
    /// then walked up to fourteen folders calling `isExecutableFile` on each.
    /// Ten cards on the dashboard meant roughly seventy dictionary builds and
    /// close to a thousand filesystem probes every time the window drew, on the
    /// thread that draws it.
    ///
    /// The answer cannot change within one draw — nothing here mutates it — so
    /// it is computed once and passed down. The values are still re-read from
    /// `state` on every draw, so a card updates the moment the tool moves.
    var body: some View {
        let location = state.location(of: tool)
        let isLinked = state.isToolLinked(tool)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(
                    icon: AgentPresentation.icon(forTool: tool.id),
                    color: AgentPresentation.tint(forTool: tool.id),
                    size: 30
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(tool.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)

                        badge(location)
                    }

                    Text(subtitle(location, isLinked))
                        .font(.system(size: 11))
                        .foregroundStyle(location == nil ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            footer(location, isLinked)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
    private func badge(_ location: ToolLocator.Location?) -> some View {
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
    private func subtitle(_ location: ToolLocator.Location?, _ isLinked: Bool) -> String {
        guard let location else {
            // The card cannot install anything, so the useful thing it can do
            // for a tool that is nowhere is name the command that would change
            // that. A catalog entry carries one; a hand-added tool may not.
            if let install = tool.installCommand, !install.isEmpty { return install }
            return "Not on your Mac, or in the sandbox."
        }
        switch location {
        case .sandbox:
            return isLinked ? "Linked into the sandbox by JXCode." : tool.tagline
        case .host:
            return "Installed on your Mac, outside the sandbox."
        }
    }

    @ViewBuilder
    private func footer(_ location: ToolLocator.Location?, _ isLinked: Bool) -> some View {
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

            // Only for tools the user added. A built-in is not removable —
            // `saveCustom()` persists only the non-built-in entries, so deleting
            // one would appear to work and then come back on the next launch.
            if state.toolRegistry.isCustom(id: tool.id) {
                Button {
                    state.removeTool(id: tool.id)
                } label: {
                    MXIconView(name: .trash, size: 11, tint: Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(tool.name) from the dashboard")
            }
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
        // The catalog's entries. Listed rather than defaulted because the
        // fallback is `.terminal`, and a grid where six cards share one glyph
        // reads as a rendering bug.
        case "aider":    return .code
        case "crush":    return .terminal
        case "amp":      return .bolt
        case "qwen":     return .sparkle
        case "droid":    return .cpuBolt
        case "kilo":     return .code
        case "copilot":  return .sparkle
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
        case "shell":        return .terminal
        case "herdr":        return .layers
        case "jcode":        return .code
        case "hermes":       return .layers
        case "aider":        return .code
        case "goose":        return .terminal
        case "crush":        return .terminal
        case "amp":          return .bolt
        case "cursor-agent": return .arrowUpRight
        case "qwen":         return .sparkle
        default:             return .terminal
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
        default:         return "Custom agent"
        }
    }

    /// The card's description, preferring the agent's own.
    ///
    /// A catalog entry or a hand-added agent carries its `tagline` with it; the
    /// table above is only what the built-ins use, because their wording was
    /// written and reviewed here and moving user-facing copy into
    /// `AgentRegistry.builtIns` would buy nothing. Consulting the agent first is
    /// what stops a newly added one from being described as "Custom agent"
    /// forever.
    static func tagline(for agent: AgentDefinition) -> String {
        if let own = agent.tagline, !own.isEmpty { return own }
        return tagline(for: agent.id)
    }
}

// MARK: - Sheets

struct NewWorkspaceSheet: View {
    @EnvironmentObject private var state: AppState
    /// Where the new folder is created. `nil` = the sandbox's own
    /// `workspaces/` — the default, and what every previous workspace got.
    @State private var customLocation: URL?
    @State private var locationIsCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New workspace")
                .font(.system(size: 15, weight: .medium))

            TextField("Name", text: $state.newWorkspaceName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(create)

            Divider()

            Toggle("Choose location…", isOn: $locationIsCustom)
                .font(.system(size: 12))
            if locationIsCustom {
                HStack(spacing: 8) {
                    Text(customLocation?.path ?? "No folder chosen")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(customLocation == nil ? Theme.warning : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Browse…", action: choose)
                }
                Text("The workspace folder is created inside the folder you "
                    + "pick — the toolchain stays sandboxed either way.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("A directory is created inside the sandbox.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.newWorkspaceName = ""
                    state.promptForWorkspace = false
                }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty
                        || (locationIsCustom && customLocation == nil))
            }
        }
        .padding(20)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The workspace folder is created inside this directory."
        if panel.runModal() == .OK, let url = panel.url {
            customLocation = url
        }
    }

    private func create() {
        state.createWorkspace(
            named: state.newWorkspaceName,
            in: locationIsCustom ? customLocation : nil
        )
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
