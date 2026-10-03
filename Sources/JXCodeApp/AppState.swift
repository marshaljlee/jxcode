import AppKit
import Foundation
import JXCodeCore
import SwiftUI

/// Live health of the one-off served model.
///
/// `isServing` only records that a server was *started* — it is a flag set once
/// and never revisited, so on its own it answers "is the model still loaded?"
/// with a stale yes forever, including after the process has died. This is the
/// polled answer, and the reason the UI can say anything truthful about a
/// process it does not own.
///
/// Named apart from the core's `ServerHealth` on purpose. That one describes a
/// *supervised* server — six cases, because a supervisor has to decide whether
/// to wait, read the log, restart, or give up — and this one describes the
/// single server `serve this model` starts, which the app owns outright. Two
/// types with one name in one target is how a reader comes to believe the pane
/// is showing the supervisor's verdict when it is showing this one.
enum LocalServerHealth: Equatable {
    case idle
    case loading
    case healthy
    /// Process alive but not answering. Usually a long generation blocking the
    /// loop, so this is retried rather than declared dead.
    case unreachable
    /// The process is gone. Unrecoverable without a restart.
    case exited

    var label: String {
        switch self {
        case .idle:        return "not loaded"
        case .loading:     return "loading…"
        case .healthy:     return "loaded"
        case .unreachable: return "not responding"
        case .exited:      return "stopped unexpectedly"
        }
    }

    var isUp: Bool { self == .healthy }

    /// The glyph for this state, as a vendored icon rather than an SF
    /// Symbol name — so a typo is a compile error, not a blank indicator.
    var icon: MXIconName {
        switch self {
        case .idle:        return .circle
        case .loading:     return .refresh
        case .healthy:     return .check
        case .unreachable: return .warning
        case .exited:      return .close
        }
    }
}

/// A step of the activation chain that could not be taken.
///
/// Its own type rather than an `NSError`, because every one of these becomes the
/// `detail` of a step in the report — the chain does not reword what it is told,
/// so the message has to already be the sentence the user reads.
struct ActivationRefusal: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@MainActor
final class AppState: ObservableObject {

    let sandbox: Sandbox
    let registry: AgentRegistry
    /// The dashboard's tools: the built-ins plus whatever the user added.
    let toolRegistry: ToolRegistry
    /// Which agent is in charge, and what it has been told it may do.
    ///
    /// Its own store rather than a field on the registry because the registry is
    /// the list of agents that exist and the primary is a claim about one of
    /// them — different lifetimes, and they should not fail together.
    let primaryStore: PrimaryAgentStore
    /// The charter handed to the primary. Empty until one is chosen.
    let primaryCharter = PrimaryCharter()

    /// The current primary, or `nil`.
    ///
    /// Published and re-read from disk rather than kept in step by hand, so the
    /// badge on an agent card and the record the CLI reads cannot disagree — the
    /// same reason `systemPrompt` is a value re-read on change.
    @Published var primary: PrimaryAgent?

    /// Whether the pick-a-primary sheet is open.
    @Published var showPrimaryPicker = false

    /// Whether the choose-the-sandbox-folder sheet is open.
    @Published var showSandboxLocation = false

    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: UUID?
    @Published var tabs: [TabItem] = []
    @Published var selectedTabID: UUID?

    @Published var doctorReport: DoctorReport?
    @Published var banner: String?
    @Published var promptForWorkspace = false
    @Published var newWorkspaceName = ""
    @Published var showInspector = false
    @Published var importSummary: String?
    /// Whether the model-routing pane is open. Global config, not per workspace.
    @Published var showProviders = false

    // MARK: Mainframe chrome

    /// Whether the sidebar is shown. The mainframe is an `HStack` of sidebar and
    /// main column, so collapsing is removing one side of that stack — which is
    /// how the terminal apps this shape comes from behave.
    @Published var isSidebarCollapsed = false
    /// Whether the bottom status bar is shown. Some people want the pixels.
    @Published var isStatusBarVisible = true

    /// Whether the main column shows the workspace's landing/dashboard instead
    /// of the selected tab.
    ///
    /// The dashboard is a *state*, not a tab: it cannot be closed, reordered or
    /// forgotten, and the tabs keep running behind it. `selectedTabID == nil`
    /// already meant "nothing selected", so the dashboard is exactly that state
    /// made reachable — `showDashboard` selects nothing, and opening any tab
    /// selects it again.
    @Published private(set) var showDashboard = true

    // MARK: System prompt (shared, source of truth on disk)

    /// The shared system prompt, re-read from disk. A class stored elsewhere
    /// would need manual refresh announcements; a value re-read on change is
    /// one less thing to drift.
    @Published var systemPrompt = SystemPrompt(body: "", enabled: false)
    /// Last binder or save outcome, for the pane's status line.
    @Published var systemPromptStatus: String?

    // MARK: YOLO mode

    /// Global YOLO switch. When on, every agent launched *from here on*
    /// starts with its approval gates skipped; running tabs keep whatever they
    /// were started with. Off by default, always.
    @Published var isYOLOEnabled = false {
        didSet {
            guard oldValue != isYOLOEnabled else { return }
            yoloArguments = isYOLOEnabled ? activeYOLOArguments() : []
        }
    }
    /// The arguments the next launch will receive. Kept as state rather than
    /// derived at launch time so the UI can show the exact argv delta.
    @Published private(set) var yoloArguments: [String] = []

    /// Collect the YOLO argv for every installed, supported agent.
    ///
    /// The launch seam appends `yoloArguments` to any agent, so this has to be
    /// the *union* of per-agent flags rather than one agent's — a session with
    /// Claude and Codex tabs open gets both flags handed to the right
    /// processes, each agent ignoring the other's.
    private func activeYOLOArguments() -> [String] {
        var seen = Set<String>()
        var all: [String] = []
        for agent in registry.agents where YOLOMode.isSupported(agentID: agent.id) {
            for argument in YOLOMode.flags(for: agent.id)?.arguments ?? []
            where seen.insert(argument).inserted {
                all.append(argument)
            }
        }
        return all
    }

    // MARK: Providers and routing

    let providerStore: ProviderStore
    let routerState: RouterState
    let router: ModelRouter

    @Published var providers: [Provider] = []
    @Published var selectedProviderID: UUID?
    @Published var selectedModel: String?
    @Published var routerRunning = false
    @Published var routerPort: UInt16 = RouterConfiguration.defaultPort
    /// Result of the last probe or router action, shown in the pane.
    @Published var providerStatus: String?
    @Published var isProbing = false
    @Published var bindReports: [AgentConfigWriter.Report] = []
    @Published var routerLogLines: [String] = []
    /// The last request the backend rejected, if any.
    ///
    /// Surfaced on its own rather than left in the log: a provider with no
    /// credit returns 403 and the agent simply produces nothing, which reads
    /// as "routing is broken" rather than "this backend is refusing us".
    @Published var lastRouterError: String?
    /// What the most recent translation could not carry.
    ///
    /// Kept apart from the log for the same reason `lastRouterError` is, and for
    /// a different kind of user: a dropped `tool_result` or a thinking
    /// signature is not a failure, so it never appears in the error banner, but
    /// it is the answer to "why did the agent stop seeing the tool output".
    @Published var lastTranslationNotes: [String] = []

    /// Draft fields for the "add provider" form.
    @Published var newProviderName = ""
    @Published var newProviderBaseURL = ""
    @Published var newProviderKey = ""
    @Published var newProviderKind: ProviderKind = .openAICompatible

    // MARK: Local models (pillar 03)

    /// Whether the local-model library is open.
    @Published var showModels = false
    @Published var modelScan: ModelLibraryScan?
    @Published var isScanningModels = false
    @Published var modelRoots: [String] = AppState.storedModelRoots()
    @Published var selectedModelID: String?
    @Published var modelPlan: OptimizationPlan?
    @Published var modelStatus: String?
    @Published var memoryPolicy: MemoryPolicy = .safe
    @Published var cachePolicy: CachePolicy = .balanced

    /// The located `llama-server`, and where it came from. `nil` means none was
    /// found, which is a normal state the pane explains rather than an error.
    @Published var llamaRuntime: LlamaRuntime?
    /// What that binary accepts, asked once and memoised on its identity.
    ///
    /// Held rather than re-probed because the one-router section below reads it
    /// on every lifecycle refresh, and an unmemoised `--help` would launch a
    /// process each time.
    @Published var serverCapabilities: LlamaServerCapabilities = .assumedModern
    /// The one-router decision as this machine sees it, for the pane.
    ///
    /// Rebuilt rather than computed in the view: it reads the installed binary
    /// and the list of running servers, and a view body is not a place to run a
    /// probe — that is the defect `RunningServers` was moved into the core for.
    @Published var servingPolicyText: String = ""
    @Published var servedModelID: String?
    @Published var servedPort: Int?
    /// What the running server says it loaded, as opposed to what the plan
    /// predicted. `nil` until it has been asked, or if it did not answer.
    @Published var servedProps: ServerProps?
    /// Where the server and the plan disagree. Empty is the good case.
    @Published var servedDisagreements: [String] = []

    /// The result of asking the running server to call a tool.
    ///
    /// `servedProps` is the template saying what it *can* do; this is the model
    /// *doing* it. The gap between them is the failure this app is otherwise
    /// blind to — a template that renders `tool_calls` without ever reading
    /// `tools` reports `supports_tool_calls=true` and then answers every agent
    /// request in prose, with no error anywhere.
    @Published var servedToolProbe: ToolProbe.Outcome?
    /// Whether a probe is in flight, so the button can say so rather than
    /// appearing to do nothing for the second it takes.
    @Published var isProbingTools = false

    /// Live state of the local server, refreshed by the poll below.
    @Published var serverHealth: LocalServerHealth = .idle
    /// When the last poll ran, so the UI can say "checked 4s ago" instead of
    /// implying the dot is a live connection.
    @Published var lastHealthCheck: Date?
    /// Consecutive failed polls. One miss is usually a long generation blocking
    /// the health loop, so death is only declared after several.
    @Published var healthFailures = 0
    /// Tail captured at the moment the server was found dead. The log is the
    /// only record of why, and it is gone once the process is reaped.
    @Published var serverDeathLog: String?

    /// Held so the child process can be stopped.
    private var llamaServer: LlamaServer?
    private var healthTask: Task<Void, Never>?

    // MARK: Model lifecycle (track 1.3)

    /// The alias table and the idle policy. The same file `jxcode local` edits,
    /// so the two surfaces cannot disagree about what a name means.
    let lifecycleStore: ModelLifecycleStore

    /// Starts a model when a request names its alias, stops it when nothing has
    /// for a while.
    ///
    /// Held here and *attached* to the router separately, rather than folded
    /// into `RouterState`'s configuration. That configuration is compared with
    /// `==` to decide whether a running listener still matches what the UI
    /// shows, and a live object with no stable value in that comparison would
    /// make every attach and detach read as "the configuration changed".
    let modelSupervisor: LlamaServerSupervisor

    @Published var runningModels: [RunningModel] = []
    /// The core's verdict on each loaded server, keyed by alias. Unqualified
    /// `ServerHealth` here is `JXCodeCore.ServerHealth` — see `LocalServerHealth`
    /// above for the one this file used to declare.
    @Published var lifecycleHealth: [String: ServerHealth] = [:]
    @Published var lifecycleMetrics: [String: ServerMetricsReport] = [:]
    @Published var lifecycleStatus: String?
    /// `llama-server` processes this app did not start, matched back to aliases.
    @Published var foreignServers: [ModelLifecycleReport.ForeignServer] = []

    /// Which of the four streams the pane is showing, and for which model.
    ///
    /// `model` is the only per-model stream; `logStreamAlias` is ignored for the
    /// other three, which are shared by every server.
    @Published var logStream: ModelLogStream = .proxy
    @Published var logStreamAlias: String?
    @Published var logStreamTail: String = ""

    /// `~/Models` when it exists. Not assumed: a machine without it simply
    /// starts with an empty list and an invitation to pick a directory.
    /// Model folders are a fact about the user's machine, not about the sandbox,
    /// so they live in `UserDefaults` rather than under the sandbox root — a
    /// throwaway sandbox must not forget where the models are.
    private static let modelRootsKey = "app.jxcode.modelRoots"

    /// Saved roots if they have ever been configured, otherwise the discovered
    /// ones.
    ///
    /// "Never configured" and "configured to nothing" are different states, so
    /// this keys off the *presence* of the stored value, not its emptiness: an
    /// empty saved array means the user deleted every folder, and falling back
    /// to the defaults would resurrect the ones they just removed.
    static func storedModelRoots() -> [String] {
        guard let saved = UserDefaults.standard.object(forKey: modelRootsKey) as? [String] else {
            return defaultModelRoots()
        }
        return saved
    }

    private func persistModelRoots() {
        UserDefaults.standard.set(modelRoots, forKey: Self.modelRootsKey)
    }

    static func defaultModelRoots() -> [String] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = ["Models", "models", ".cache/llama.cpp", "Library/Application Support/models"]
        var roots: [String] = []
        for candidate in candidates {
            let url = home.appendingPathComponent(candidate)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                roots.append(url.path)
            }
        }
        return roots
    }

    private let store: WorkspaceStore

    init() {
        // The environment policy belongs to the user, so the app has to run with
        // the same one the CLI reads. Building a bare `Sandbox()` here would give
        // the GUI a default environment and the CLI a configured one, which is
        // the exact drift `sandbox.json` exists to prevent. The router is not
        // lost by this: it arrives through `Sandbox.routerSeam`, not through the
        // options passed here.
        let paths = SandboxPaths.default
        let configuration = SandboxConfigurationStore(paths: paths).configuration
        let sandbox = Sandbox(paths: paths, options: configuration.options())
        self.sandbox = sandbox
        self.registry = AgentRegistry(paths: sandbox.paths)
        self.toolRegistry = ToolRegistry(paths: sandbox.paths)
        self.primaryStore = PrimaryAgentStore(paths: sandbox.paths)
        self.folderStore = ProjectFolderStore(paths: sandbox.paths)
        self.store = WorkspaceStore(paths: sandbox.paths)
        self.sharedStore = SharedStore(paths: sandbox.paths)

        self.providerStore = ProviderStore(paths: sandbox.paths)

        let lifecycleStore = ModelLifecycleStore(paths: sandbox.paths)
        let supervisor = LlamaServerSupervisor(store: lifecycleStore, paths: sandbox.paths)
        self.lifecycleStore = lifecycleStore
        self.modelSupervisor = supervisor

        self.routerState = RouterState()
        self.router = ModelRouter(
            state: routerState,
            log: RouterLog(fileURL: sandbox.paths.logs.appendingPathComponent("router.log")),
            // The access log, written before the router decides anything. A
            // separate file rather than more lines in the decision log, because
            // "the agent sent nothing" and "the agent sent something the router
            // refused" are the same shape in a decision log and opposite
            // diagnoses. This is the `http` stream the pane offers.
            httpLog: RouterLog(fileURL: sandbox.paths.logs.appendingPathComponent("http.log"))
        )

        // Attaching the supervisor is what makes an agent's request for `coder`
        // load a model. Without this line the router's alias path is
        // unreachable, and a request for an alias falls through to the
        // configured model — silently, because that fallback is exactly what a
        // name the router has never heard of is supposed to get.
        routerState.update(serving: supervisor)
    }

    // MARK: - Bootstrap

    func bootstrap() {
        do {
            try sandbox.prepare()
        } catch {
            banner = "Sandbox setup failed: \(error)"
            return
        }

        workspaces = store.workspaces

        if workspaces.isEmpty {
            // A brand-new install should not present an empty window.
            //
            // `try?` here would leave an empty sidebar with nothing to read,
            // which is the one state the user cannot act on: there is nothing
            // to click and nothing to explain why. A failure here means the
            // state file cannot be written, so every later create fails too —
            // naming the file and the reason is the difference between a
            // solvable problem and a mystery.
            do {
                let first = try store.create(name: "scratch")
                workspaces = store.workspaces
                selectedWorkspaceID = first.id
            } catch {
                banner = "The sandbox is ready, but its first workspace could not be "
                    + "saved to \(sandbox.paths.workspacesFile.path): \(error). "
                    + "Creating one by hand will fail the same way until that file "
                    + "can be written."
            }
        } else if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }

        refreshProviders()
        refreshDoctor()
        refreshInstalledAgents()
        refreshPrimary()
        refreshFolders()
        refreshTools()
        refreshShared()
        // Load the token before anything can start the router, so the first
        // request is judged against the real policy rather than a default.
        loadRouterAuth()
        refreshGitStatuses()
        refreshSystemPrompt()

        // The idle sweep is a convenience, not the mechanism — a laptop that
        // sleeps fires no timers, which is why `sweep()` is also reachable from
        // the pane and from `jxcode local sweep`. Starting it here means the
        // ordinary case needs no button anywhere.
        modelSupervisor.startSweeping()
        reloadLifecycle()
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    // MARK: - Workspaces

    func createWorkspace(named name: String, in base: URL? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let workspace = try store.create(name: trimmed, in: base)
            workspaces = store.workspaces
            selectedWorkspaceID = workspace.id
            tabs = []
            selectedTabID = nil
            showDashboard = true
            refreshGitStatuses()
        } catch {
            banner = "Could not create workspace: \(error)"
        }
    }

    func deleteWorkspace(id: UUID) {
        // Only forgets the workspace; the directory on disk is left alone.
        //
        // `remove` takes the row out of the in-memory list before it writes the
        // file, so a failed write would leave the sidebar showing a deletion
        // that never happened and the workspace back on the next launch. Re-read
        // from disk on failure so the list matches what is really stored.
        do {
            try store.remove(id: id)
        } catch {
            store.load()
            workspaces = store.workspaces
            gitStatuses.removeValue(forKey: id)
            if selectedWorkspaceID == id {
                selectedWorkspaceID = workspaces.first?.id
                tabs = []
                selectedTabID = nil
            }
            banner = "Could not remove that workspace: \(error)"
            return
        }
        workspaces = store.workspaces
        gitStatuses.removeValue(forKey: id)
        if selectedWorkspaceID == id {
            selectedWorkspaceID = workspaces.first?.id
            tabs = []
            selectedTabID = nil
        }
    }

    // MARK: - Tabs

    /// Agents currently being installed. Doubles as the "a second click must
    /// not start a second `npm i`" guard and as the card's progress state.
    @Published var installingAgentIDs: Set<String> = []
    /// What each in-flight install is doing, so the card can say more than
    /// "spinner".
    @Published var installProgress: [String: String] = [:]
    /// Why the last install of an agent failed, keyed by agent id. Kept rather
    /// than cleared so the row can keep showing that it needs attention.
    @Published var installFailures: [String: String] = [:]

    /// Which agents resolve to a binary right now.
    ///
    /// Cached because the launcher draws one row per agent and each lookup walks
    /// the sandbox `PATH` — cheap once, wasteful seven times per redraw.
    @Published private(set) var installedAgentIDs: Set<String> = []

    func refreshInstalledAgents() {
        // `PATH` does not vary by workspace, so one environment answers for all
        // of them.
        let environment = sandbox.env(workspace: selectedWorkspace)
        installedAgentIDs = Set(
            registry.agents
                .filter { registry.isInstalled($0, environment: environment) }
                .map(\.id)
        )
    }

    func isInstalled(agentID: String) -> Bool {
        installedAgentIDs.contains(agentID)
    }

    // MARK: - Project folders

    /// The folders the person has worked in, pinned and recent.
    @Published var folders = ProjectFolders()

    let folderStore: ProjectFolderStore

    /// Re-read the folder list.
    func refreshFolders() {
        folders = folderStore.load()
    }

    /// Note that a folder was worked in.
    ///
    /// Called from the paths that already mean "this folder was used": adopting
    /// a workspace, and opening one. Re-recording an existing folder bumps its
    /// timestamp and count instead of adding a second row, so repeatedly opening
    /// the same project does not fill the sidebar with copies of itself.
    func recordFolderUse(path: String, name: String? = nil) {
        var updated = folders
        updated.recordVisit(path: path, name: name)
        // All three of these used to `guard ... else { return }` on the `Bool`,
        // which left a failed write invisible: the sidebar did not change and
        // nothing said why, so a click on pin or forget looked like the app had
        // ignored it. The write is the thing that can fail here, so it is the
        // thing that reports.
        do {
            try folderStore.saveChecked(updated)
        } catch {
            banner = "Could not record that folder in \(folderStore.fileURL.path): \(error)"
            return
        }
        folders = updated
    }

    /// Pin or unpin a folder.
    func togglePin(path: String) {
        var updated = folders
        guard let entry = updated.entries.first(where: { $0.path == path }) else { return }
        updated.setPinned(!entry.isPinned, path: path)
        do {
            try folderStore.saveChecked(updated)
        } catch {
            banner = "Could not change the pin in \(folderStore.fileURL.path): \(error)"
            return
        }
        folders = updated
        banner = updated.entries.first(where: { $0.path == path })?.isPinned == true
            ? "Pinned."
            : "Unpinned."
    }

    /// Drop a folder from the list entirely, pin and history both.
    func forgetProjectFolder(path: String) {
        var updated = folders
        updated.remove(path: path)
        do {
            try folderStore.saveChecked(updated)
        } catch {
            banner = "Could not remove \(path) from \(folderStore.fileURL.path): \(error)"
            return
        }
        folders = updated
    }

    /// Open a folder as a workspace, and remember that we did.
    ///
    /// `adoptWorkspace()` does the recording — it goes through
    /// `WorkspaceStore.adopt`, which is the one place that writes the folder
    /// history. This wrapper only exists so a folder row reads as one click.
    func openProjectFolder(_ entry: ProjectFolders.Entry) {
        adoptPath = entry.path
        adoptName = entry.name
        adoptWorkspace()
    }

    func revealProjectFolder(_ entry: ProjectFolders.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    // MARK: - Primary operator

    /// Re-read the primary record, dropping it if the agent it names is gone.
    ///
    /// A record pointing at an agent the user has since deleted is worse than no
    /// record: the badge would sit on nothing, and the charter would tell a
    /// primary it cannot reach. So the id is checked against the live registry and
    /// the stale file is removed rather than left to be read again next launch.
    func refreshPrimary() {
        guard let record = primaryStore.load() else {
            primary = nil
            return
        }
        guard registry.agent(id: record.agentID) != nil else {
            primaryStore.clear()
            primary = nil
            return
        }
        primary = record
    }

    /// Whether this agent is the one in charge.
    func isPrimary(agentID: String) -> Bool {
        primary?.agentID == agentID
    }

    /// The agents this primary may hand work to.
    ///
    /// Everything but itself, and only what is actually installed — the charter
    /// is built from this, so a subagent the primary cannot launch is never
    /// offered to it.
    var availableSubagents: [AgentDefinition] {
        // From the cache rather than by probing.
        //
        // This was `sandbox.env(workspace:)` plus a `resolvedPath` walk per
        // agent, on every single read — and `PrimaryPickerSheet` reads it from
        // its own `body`, so the picker redrew by re-resolving every agent
        // binary on disk. `refreshInstalledAgents()` answers the same question
        // with the same call and already exists for this reason.
        //
        // Safe to reuse: `isInstalled` resolves against `PATH`, and `PATH` is
        // rebuilt by `buildPath()` from the sandbox paths and
        // `options.extraPathEntries` only. The router seam that `env()` applies
        // per call changes `routerURL`/`routerToken`, which become their own
        // keys and never touch `PATH`. So the answer cannot go stale when the
        // router starts or stops — the two things that do change it, an agent
        // being installed and the catalog changing, both call the refresh.
        registry.agents.filter { $0.id != primary?.agentID && installedAgentIDs.contains($0.id) }
    }

    /// Make `agentID` the primary, and hand it its charter.
    ///
    /// The charter is typed into the agent's terminal *after* it has started, so
    /// the first thing it reads is what it is for. Typing it is the only channel
    /// jxcode has into a CLI agent, and doing it at launch rather than asking the
    /// user to paste something is the difference between a feature that works
    /// and a feature that is documented.
    @discardableResult
    func setPrimary(agentID: String, maxSubagents: Int, canInstallTools: Bool) -> Bool {
        guard let agent = registry.agent(id: agentID) else {
            banner = "No agent with id “\(agentID)”. Run jxcode agents to see the list."
            return false
        }

        let record = PrimaryAgent(
            agentID: agent.id,
            agentName: agent.name,
            maxSubagents: maxSubagents,
            canInstallTools: canInstallTools
        )
        guard primaryStore.save(record) else {
            banner = "Could not save the primary record to \(primaryStore.fileURL.path)."
            return false
        }
        primary = record
        showPrimaryPicker = false

        // Open the primary's tab if it is not already running, so choosing a
        // primary does something visible instead of only writing a file.
        openTab(agentID: agentID)
        return true
    }

    /// Stop treating any agent as in charge.
    func clearPrimary() {
        guard primary != nil else { return }
        if primaryStore.clear() {
            primary = nil
            banner = "No primary agent. Every agent is now on its own."
        } else {
            banner = "Could not remove \(primaryStore.fileURL.path)."
        }
    }

    /// The charter text for the current primary.
    var primaryCharterText: String {
        guard let primary else { return "" }
        return primaryCharter.charter(
            primary: primary,
            subagents: registry.agents,
            environment: sandbox.env(workspace: selectedWorkspace)
        )
    }

    /// The charter, for the CLI.
    func plainPrimaryCharter() -> String {
        guard let primary else { return "" }
        return primaryCharter.plainCharter(
            primary: primary,
            subagents: registry.agents,
            environment: sandbox.env(workspace: selectedWorkspace)
        )
    }

    /// Open an agent's tab, installing it first if it is not there yet.
    ///
    /// This is the whole of the launcher's contract: one click, and either the
    /// agent is running or the user is told exactly why it is not.
    func openTab(agentID: String) {
        guard let workspace = selectedWorkspace,
              let agent = registry.agent(id: agentID) else { return }

        let environment = sandbox.env(workspace: workspace)
        if registry.isInstalled(agent, environment: environment) {
            launch(agent: agent, workspace: workspace)
            return
        }

        install(agent: agent, workspace: workspace)
    }

    /// Install an agent, then open its tab.
    ///
    /// What this replaced: opening a *shell* tab and typing the install command
    /// into it after a 0.7 second delay. That could not work — `npm` is not on
    /// the sandbox `PATH` — and even when it could have, nothing read the exit
    /// status, so a failure produced a shell prompt instead of an explanation
    /// and there was nothing to retry. See `AgentInstaller`.
    private func install(agent: AgentDefinition, workspace: Workspace) {
        guard !installingAgentIDs.contains(agent.id) else { return }

        guard agent.installCommand != nil else {
            banner = "\(agent.name) is not installed and has no install command. "
                + "Add one with “Add an agent…”."
            return
        }

        installingAgentIDs.insert(agent.id)
        installProgress[agent.id] = "Preparing…"
        installFailures.removeValue(forKey: agent.id)

        let sandbox = self.sandbox
        let agentID = agent.id

        Task.detached(priority: .userInitiated) {
            let outcome = AgentInstaller.install(
                agent: agent,
                sandbox: sandbox,
                workspace: workspace,
                onProgress: { message in
                    Task { @MainActor in self.installProgress[agentID] = message }
                }
            )

            await MainActor.run {
                self.installingAgentIDs.remove(agentID)
                self.installProgress.removeValue(forKey: agentID)
                self.refreshInstalledAgents()

                switch outcome.status {
                case .installed(let path):
                    self.banner = "\(outcome.agentName) is installed inside the sandbox "
                        + "(\(sandbox.paths.display(URL(fileURLWithPath: path))))."
                    // Now that it resolves, this takes the ordinary launch path.
                    self.openTab(agentID: agentID)

                case .failed(_, let message):
                    self.installFailures[agentID] = message
                    self.banner = message
                }
            }
        }
    }

    /// Start an installed agent in a new tab.
    private func launch(agent: AgentDefinition, workspace: Workspace) {
        // Say so before it starts, not after.
        //
        // Claude Code decides whether it is logged in before it makes a
        // request. With no router and no stored credential it prints
        // `Not logged in · Please run /login` and exits 1 — which reads as a
        // broken install rather than as "nothing is serving it". The same is
        // true of Codex. Both are only reachable through the router here.
        if agent.routerBinding == .claudeSettings || agent.routerBinding == .codexConfig,
           sandbox.routerURL == nil {
            banner = "\(agent.name) has no route to a model. Start routing in "
                + "Model routing (or run /login inside it to use your own "
                + "account) — otherwise it exits with \"not logged in\"."
        }

        let controller = TerminalController(
            agent: agent,
            sandbox: sandbox,
            workspace: workspace,
            launchArguments: yoloArguments
        )
        let tab = TabItem(terminal: controller)
        tabs.append(tab)
        selectedTabID = tab.id
        showDashboard = false
        controller.start()

        // If this agent is the one in charge, tell it so now rather than leaving
        // the human to paste something. Only on the launch that actually starts
        // the process — re-opening a tab that is already running would type the
        // charter a second time into a conversation that already has it.
        if isPrimary(agentID: agent.id) {
            let charter = primaryCharterText
            controller.deliverCharter(charter)
        }
    }

    /// Open an agent's web dashboard as an embedded panel.
    ///
    /// Only meaningful for agents that declare a `webURL`. Jules is the case
    /// that needs it — the CLI dispatches async work to a cloud VM, and the
    /// dashboard is where you watch it run.
    func openWebPanel(agentID: String) {
        guard let agent = registry.agent(id: agentID),
              let urlString = agent.webURL,
              let url = URL(string: urlString) else { return }

        let controller = WebPanelController(title: agent.name, url: url)
        let tab = TabItem(web: controller)
        tabs.append(tab)
        selectedTabID = tab.id
        showDashboard = false
    }

    // MARK: - Tools

    /// The tools the dashboard offers: the built-ins plus the user's own.
    ///
    /// A published mirror rather than a computed property. It used to be
    /// `ToolCatalog.builtIns` read straight through, which was correct while the
    /// list was a constant — and became wrong the moment it was not, because
    /// SwiftUI has nothing to observe on a computed property and adding a tool
    /// would not have redrawn the grid.
    @Published private(set) var tools: [ToolDefinition] = []

    /// Draft fields for the "add tool" form.
    @Published var showAddTool = false
    @Published var newToolName = ""
    @Published var newToolBinary = ""
    @Published var newToolArguments = ""
    @Published var newToolTagline = ""
    @Published var newToolInstallCommand = ""

    func refreshTools() {
        tools = toolRegistry.tools
    }

    /// The catalog entries the dashboard is not already showing.
    var suggestedTools: [ToolDefinition] {
        ToolCatalog.suggestions(absentFrom: tools)
    }

    /// The catalog agents the launcher is not already showing.
    var suggestedAgents: [AgentDefinition] {
        AgentCatalog.suggestions(absentFrom: registry.agents)
    }

    /// Where a tool is, or `nil` when it is nowhere.
    ///
    /// Two different sources on purpose. The sandbox lookup reads the *sandbox*
    /// `PATH`, because the question is "could an agent run this". The host
    /// fallback reads a fixed list of directories, because the app's own `PATH`
    /// is not the user's — launched from Finder it is minimal, and every one of
    /// those directories is missing from it.
    func location(of tool: ToolDefinition) -> ToolLocator.Location? {
        ToolLocator.locate(tool, environment: sandbox.env(workspace: selectedWorkspace))
    }

    /// Register a CLI the catalog does not know about.
    ///
    /// The registry always supported custom tools — it loads `tools.json` — but
    /// nothing wrote to it, so the only way to add one was to hand-edit JSON.
    /// The app launches arbitrary CLIs by design, so its list should not be a
    /// closed set.
    func addTool(_ tool: ToolDefinition) {
        do {
            try toolRegistry.add(tool)
            refreshTools()
            banner = "\(tool.name) added to the dashboard."
        } catch {
            banner = "Could not add that tool: \(error)"
        }
    }

    /// Register the manual form's contents.
    func addCustomTool() {
        let name = newToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let binary = newToolBinary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !binary.isEmpty else {
            banner = "A tool needs both a name and a command."
            return
        }

        let arguments = newToolArguments
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        let install = newToolInstallCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagline = newToolTagline.trimmingCharacters(in: .whitespacesAndNewlines)

        addTool(ToolDefinition(
            id: ToolRegistry.slug(for: name),
            name: name,
            binary: binary,
            arguments: arguments,
            tagline: tagline.isEmpty ? "Added by you" : tagline,
            installCommand: install.isEmpty ? nil : install
        ))

        newToolName = ""
        newToolBinary = ""
        newToolArguments = ""
        newToolTagline = ""
        newToolInstallCommand = ""
        showAddTool = false
    }

    /// Forget a tool the user added.
    func removeTool(id: String) {
        do {
            guard try toolRegistry.remove(id: id) else {
                banner = "That tool ships with JXCode, so it cannot be removed."
                return
            }
            refreshTools()
        } catch {
            banner = "Could not remove that tool: \(error)"
        }
    }

    /// Register an agent from the catalog, without the manual form.
    func addSuggestedAgent(_ agent: AgentDefinition) {
        do {
            try registry.add(agent)
            refreshInstalledAgents()
            banner = "\(agent.name) added. Click its card to install it in the sandbox."
        } catch {
            banner = "Could not add \(agent.name): \(error)"
        }
    }

    /// Forget an agent the user added.
    func removeAgent(id: String) {
        do {
            guard try registry.remove(id: id) else {
                banner = "That agent ships with JXCode, so it cannot be removed."
                return
            }
            refreshInstalledAgents()
        } catch {
            banner = "Could not remove that agent: \(error)"
        }
    }

    /// Open a tool in a new tab.
    ///
    /// Refuses a host-only tool rather than letting the pty fail. The launch
    /// would throw `commandNotFound` anyway, but by then the user has a tab
    /// showing an error instead of the sentence that says what to do about it.
    func launchTool(_ tool: ToolDefinition) {
        guard let workspace = selectedWorkspace else { return }
        guard location(of: tool)?.isInSandbox == true else {
            banner = "\(tool.name) is installed on your Mac but not inside the "
                + "sandbox, so an agent could not run it. Add it to the sandbox "
                + "first."
            return
        }
        let controller = TerminalController(tool: tool, sandbox: sandbox, workspace: workspace)
        let tab = TabItem(terminal: controller)
        tabs.append(tab)
        selectedTabID = tab.id
        showDashboard = false
        controller.start()
    }

    /// Open the plain shell: login zsh, inside the sandbox.
    ///
    /// Reached through the tools because that is what it is — there is no
    /// agent behind it, nothing to install, and nothing to bind a model to.
    /// Going through `launchTool` rather than building a tab directly is the
    /// point: the same "is it actually resolvable inside the sandbox" check
    /// runs, so a shell that cannot launch says so in a banner instead of
    /// in a dead terminal.
    func openShellTab() {
        guard let tool = toolRegistry.tools.first(where: { $0.id == "shell" }) else { return }
        launchTool(tool)
    }

    /// Make a host-installed tool available inside the sandbox.
    ///
    /// No success message: the card re-reads `location(of:)` and flips to
    /// "Ready in sandbox" on its own, which is a better confirmation than a
    /// sentence because it is the same control the user will press next.
    func linkTool(_ tool: ToolDefinition) {
        guard case .host(let source) = location(of: tool) else { return }
        do {
            try ToolLinker.link(tool: tool, from: source, paths: sandbox.paths)
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Remove the sandbox link this app created for a tool.
    func unlinkTool(_ tool: ToolDefinition) {
        do {
            try ToolLinker.unlink(tool: tool, paths: sandbox.paths)
        } catch {
            banner = error.localizedDescription
        }
    }

    /// True when the sandbox's copy is a link this app made, rather than an
    /// install of the user's own.
    func isToolLinked(_ tool: ToolDefinition) -> Bool {
        ToolLinker.isLinked(tool: tool, paths: sandbox.paths)
    }

    var selectedTab: TabItem? {
        guard let selectedTabID, !showDashboard else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    /// Show the workspace's landing/dashboard. Tabs keep running.
    func showDashboardTab() {
        showDashboard = true
    }

    /// Select a tab, leaving the dashboard.
    func selectTab(id: UUID) {
        selectedTabID = id
        showDashboard = false
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
            // The last tab closing lands on the dashboard, not on an empty
            // pane — the landing is the floor, and `showDashboard` is what
            // makes that true when tabs existed but none remain.
            if selectedTabID == nil {
                showDashboard = true
            }
        }
    }

    // MARK: - Doctor

    func refreshDoctor() {
        let sandbox = self.sandbox
        let registry = self.registry
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Doctor.run(sandbox: sandbox, registry: registry)
            DispatchQueue.main.async {
                self.doctorReport = report
            }
        }
    }

    var sandboxStatus: (label: String, healthy: Bool) {
        guard let report = doctorReport else { return ("checking…", true) }
        if !report.failures.isEmpty {
            return ("\(report.failures.count) leak\(report.failures.count == 1 ? "" : "s")", false)
        }
        if !report.warnings.isEmpty {
            return ("\(report.warnings.count) warning\(report.warnings.count == 1 ? "" : "s")", true)
        }
        return ("isolated", true)
    }

    // MARK: - Import

    func importFromHost(dryRun: Bool) {
        let plan = ImportService.plan(paths: sandbox.paths, realHome: NSHomeDirectory())
        if dryRun {
            importSummary = ImportService.render(plan, paths: sandbox.paths)
            showInspector = true
            return
        }
        do {
            let messages = try ImportService.apply(plan, overwrite: false)
            importSummary = messages.isEmpty
                ? "Nothing to import."
                : messages.joined(separator: "\n")
            showInspector = true
        } catch {
            banner = "Import failed: \(error)"
        }
    }

    // MARK: - Providers

    var selectedProvider: Provider? {
        if let selectedProviderID, let match = providers.first(where: { $0.id == selectedProviderID }) {
            return match
        }
        return providers.first
    }

    func refreshProviders() {
        providers = providerStore.providers
        if selectedProviderID == nil { selectedProviderID = providers.first?.id }
        if selectedModel == nil { selectedModel = selectedProvider?.models.first }
        pushRouterConfiguration()
    }

    func selectProvider(id: UUID) {
        selectedProviderID = id
        // Each backend has its own catalogue, so the previous choice is
        // meaningless here.
        selectedModel = providers.first { $0.id == id }?.models.first
        providerStatus = nil
        pushRouterConfiguration()
    }

    func selectModel(_ model: String) {
        selectedModel = model
        pushRouterConfiguration()
    }

    /// How many tokens the selected backend can actually take as input.
    ///
    /// Claude Code assumes a 200k window for any model it does not recognise,
    /// which is every local one. A GGUF handed a request that large does not
    /// fail cleanly — it decodes for minutes and then dies in a Metal
    /// allocation failure, which reads as the model, the server or the routing
    /// being broken rather than as a window it was never given room for. So the
    /// real number has to reach the agent config whenever it is known.
    ///
    /// Resolved from the **selected backend**, not from the Models pane: this is
    /// the value `bindAgents()` writes, and Bind lives in the Providers pane.
    /// Reading `modelPlan` alone meant a GGUF registered and selected there was
    /// routed with no limit at all, because `modelPlan` is nil unless a local
    /// model is also selected in the other pane.
    var routingContextLength: Int? {
        guard let provider = selectedProvider else { return nil }

        if provider.kind == .localGGUF {
            // The running server's own answer beats everything: it is measured,
            // where the plan and the stored value are both predictions.
            if let served = servedContextLength { return served }
            if let stored = provider.contextLength { return stored }
            // Last resort, and only ever right when the served model is also the
            // one selected in the Models pane.
            return modelPlan?.contextLength
        }

        return provider.contextLength
    }

    /// What the running server says its window is, regardless of what is routed.
    ///
    /// The slot division lives on `ServerProps.agentContextLength`, where it can
    /// be tested. `n_ctx` is the total across slots, so a server that opened
    /// four gives each agent a quarter — the case `disagreements` already
    /// reports as a fault, and the case `--parallel 1` exists to prevent.
    private var servedServerContext: Int? {
        servedProps?.agentContextLength
    }

    /// The served window, but only when the served server is what is routed.
    ///
    /// Split from `servedServerContext` because the two are needed at different
    /// moments: registering a backend happens before it is selected, so asking
    /// "is this the routed one?" there would always answer no and store nil.
    private var servedContextLength: Int? {
        guard let port = servedPort, servedServerContext != nil else { return nil }
        let servedBase = ProviderKind.localGGUF.normalizedBaseURL("http://127.0.0.1:\(port)")
        guard let provider = selectedProvider, provider.normalizedBaseURL == servedBase else {
            return nil
        }
        return servedServerContext
    }

    /// Mirror the UI selection into the router. The router reads this on every
    /// request, so switching model takes effect immediately.
    private func pushRouterConfiguration() {
        routerState.update(RouterConfiguration(
            provider: selectedProvider,
            model: selectedModel,
            port: routerPort
        ))
    }

    func addProvider() {
        let name = newProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else {
            providerStatus = "A name and a base URL are both required."
            return
        }

        let provider = Provider(
            name: name,
            kind: newProviderKind,
            baseURL: base,
            apiKey: newProviderKey.isEmpty ? nil : newProviderKey
        )
        do {
            try providerStore.add(provider)
        } catch {
            providerStatus = "Could not save the provider: \(error)"
            return
        }

        newProviderName = ""
        newProviderBaseURL = ""
        newProviderKey = ""
        selectedProviderID = provider.id
        selectedModel = nil
        refreshProviders()
        probeSelectedProvider()
    }

    func removeProvider(id: UUID) {
        do {
            try providerStore.remove(id: id)
        } catch {
            // `remove` drops the entry from the in-memory list before it writes
            // the file, so a failed write leaves the window showing a deletion
            // that did not happen — and the provider is back on the next launch,
            // API key and all. Re-read from disk so the list tells the truth
            // again, and say why the delete did not stick.
            providerStore.load()
            refreshProviders()
            providerStatus = "Could not remove the provider: \(error)"
            return
        }
        if selectedProviderID == id {
            selectedProviderID = nil
            selectedModel = nil
        }
        refreshProviders()
    }

    /// Fetch the model list from the selected backend and cache it.
    func probeSelectedProvider() {
        guard let provider = selectedProvider else { return }
        isProbing = true
        providerStatus = "Contacting \(provider.normalizedBaseURL)…"

        Task {
            defer { isProbing = false }
            do {
                let outcome = try await ModelCatalog().probe(provider)

                var updated = provider
                updated.models = outcome.models
                updated.lastSyncedAt = Date()
                // The probe succeeded, but caching it is a second write that can
                // fail on its own. `try?` here discarded that, and the line at
                // the end of this block still reported "N model(s) available" —
                // so a full disk produced a success message and a lost cache,
                // and the models were re-fetched from scratch every launch with
                // nothing on screen to say why. Report it and keep going: the
                // models are real, only the cache is missing.
                var cacheWarning = ""
                do {
                    try providerStore.add(updated)
                } catch {
                    cacheWarning = "\nThe model list could not be cached: \(error.localizedDescription)"
                }

                providers = providerStore.providers

                // Keep the current choice when the backend still offers it, so
                // a refresh does not silently change the routed model.
                if let current = selectedModel, outcome.models.contains(current) {
                    // unchanged
                } else {
                    selectedModel = outcome.models.first
                }

                var message = "\(outcome.models.count) model(s) available."
                if !outcome.notes.isEmpty {
                    message += "\n" + outcome.notes.joined(separator: "\n")
                }
                providerStatus = message + cacheWarning
                pushRouterConfiguration()
            } catch {
                providerStatus = "\(error)"
            }
        }
    }

    // MARK: - Router

    func startRouter() {
        guard !routerRunning else { return }
        guard selectedProvider != nil, selectedModel != nil else {
            providerStatus = "Choose a provider and a model first."
            return
        }

        pushRouterConfiguration()
        let router = self.router
        let port = routerPort

        // Binding is synchronous and can block for a moment. Keeping it off the
        // main actor avoids a visible stall in the window.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try router.start(preferredPort: port)
                DispatchQueue.main.async {
                    self.routerRunning = true
                    // Every tab launched from here inherits the router in its
                    // own environment, so an agent works even if the user
                    // never pressed Bind. Without this, Claude Code decides it
                    // is not logged in and exits instead of asking anything.
                    self.pushSandboxRouter()
                    self.providerStatus = "Router listening on \(router.baseURL)"
                    // A fresh start may well be onto a different backend, so
                    // the previous one's rejection must not linger in the UI.
                    router.log.clearError()
                    self.refreshRouterLog()
                }
            } catch {
                DispatchQueue.main.async {
                    self.routerRunning = false
                    self.providerStatus = "Could not start the router: \(error)"
                }
            }
        }
    }

    func stopRouter() {
        router.stop()
        routerRunning = false
        // Tabs launched from here on must not inherit a URL nothing answers.
        sandbox.setRouter(url: nil)
        providerStatus = "Router stopped."
        // The binding has to go with it.
        //
        // Leaving `ANTHROPIC_BASE_URL` pointed at a port nothing is listening
        // on bricks every agent: they fail with "connection refused" instead of
        // falling back to their own configuration, and the failure reads as a
        // broken agent rather than as routing being switched off.
        // `bindAgents()` refuses to bind while the router is down for exactly
        // this reason — stopping it must not quietly undo that care.
        revertAgentBindings()
        refreshRouterLog()
    }

    /// Remove the router settings this app wrote, so agents use their own.
    private func revertAgentBindings() {
        do {
            let messages = try AgentConfigWriter.revert(
                agents: registry.agents,
                paths: sandbox.paths
            )
            bindReports = []
            if !messages.isEmpty {
                providerStatus = (providerStatus ?? "")
                    + " Agents are using their own configuration again."
            }
        } catch {
            providerStatus = "Router stopped, but the agent configs could not be cleared: \(error)"
        }
    }

    func refreshRouterLog() {
        routerLogLines = router.log.snapshot()
        lastRouterError = router.log.lastError
        lastTranslationNotes = router.log.lastTranslation
    }

    // MARK: - Binding agents to the router

    /// Write each agent's config so it talks to the router.
    func bindAgents() {
        guard routerRunning else {
            // Writing the config while the router is down would point every
            // agent at a dead port, which looks like the agents are broken.
            providerStatus = "Start the router first — otherwise agents point at a dead port."
            return
        }
        guard let model = selectedModel else { return }

        // When auth is on, the agents must carry the real token or they get
        // 401s. When it is off, the placeholder keeps the written config
        // byte-identical to what it was before auth existed.
        let token = agentRouterToken

        do {
            bindReports = try AgentConfigWriter.apply(
                agents: registry.agents,
                paths: sandbox.paths,
                routerURL: router.baseURL,
                model: model,
                token: token,
                overrides: agentModelOverrides,
                wires: agentWireOverrides,
                // Known for any backend that reports a window. Without it
                // Claude Code assumes 200k and overflows a smaller model —
                // which for a local GGUF ends in a Metal allocation failure
                // minutes into the first turn, not in a tidy error.
                contextLength: routingContextLength
            )
            var message = "Agents now route through \(router.baseURL)."
            if !agentModelOverrides.isEmpty {
                message += " \(agentModelOverrides.count) using a per-agent model."
            }
            providerStatus = message
        } catch {
            providerStatus = "Could not write agent config: \(error)"
        }
    }

    func unbindAgents() {
        do {
            let messages = try AgentConfigWriter.revert(
                agents: registry.agents,
                paths: sandbox.paths
            )
            bindReports = []
            providerStatus = messages.isEmpty ? "Nothing to revert." : messages.joined(separator: "\n")
        } catch {
            providerStatus = "Could not revert agent config: \(error)"
        }
    }

    // MARK: - The shared collection

    /// The app-wide collection: skills, connectors and automations.
    ///
    /// A plain `let`, not `@Published`. `SharedStore` is a reference type whose
    /// arrays are `private(set)`, so a mutation changes the object without
    /// SwiftUI hearing about it — an `@Published` reference to a class only
    /// fires on reassignment, and nothing here is ever reassigned. The mirrors
    /// below are what the pane reads; `refreshShared()` is what fills them.
    ///
    /// Agents are deliberately not mirrored. `registry` already owns them, and a
    /// second copy of the same fact is a second thing that can be wrong.
    let sharedStore: SharedStore

    @Published var sharedSection: SharedSection = .skills

    @Published var sharedSkills: [Skill] = []
    @Published var sharedConnectors: [Connector] = []
    @Published var sharedAutomations: [Automation] = []

    /// One line per agent from the last bind or revert.
    ///
    /// Rendered to strings rather than kept as the two binders' `Report` values:
    /// they share no ancestor, and the pane shows them verbatim.
    @Published var sharedReports: [String] = []
    @Published var sharedStatus: String?
    @Published var isBindingShared = false

    /// Re-read the collection from disk and publish it.
    ///
    /// Called on every mutation rather than patched in place. The store is the
    /// source of truth and it sorts by id, so a hand-patched array would drift
    /// out of order the first time a rename changed where a row belongs.
    func refreshShared() {
        sharedStore.load()
        sharedSkills = sharedStore.skills
        sharedConnectors = sharedStore.connectors
        sharedAutomations = sharedStore.automations
    }

    /// Show one of the collection's four sections, in a tab.
    ///
    /// This used to set `showShared`, which drove a `.sheet`. A sheet was the
    /// wrong container for it: the collection is somewhere you work — add a
    /// skill, switch to a terminal to watch it get bound, come back — and a
    /// modal hides the tabs you were working in for as long as you are in it.
    /// It is a tab now, like the terminal, so it can sit beside the thing it
    /// affects.
    ///
    /// Reuses the existing tab rather than opening a second one, and only
    /// switches the section. Two shared tabs would be two views of one
    /// collection, which is a way to confuse yourself rather than a feature.
    func openShared(_ section: SharedSection) {
        sharedSection = section
        refreshShared()

        if let existing = tabs.first(where: \.isShared) {
            selectedTabID = existing.id
            showDashboard = false
            return
        }
        let tab = TabItem.sharedCollection()
        tabs.append(tab)
        selectedTabID = tab.id
        showDashboard = false
    }

    /// Close the shared collection tab, if it is open.
    ///
    /// What the pane's Done button does now that the pane is a tab: a tab has
    /// the close affordance in the tab bar too, so this is a convenience rather
    /// than the only way out — which was the other problem with the sheet.
    func closeSharedTab() {
        guard let tab = tabs.first(where: \.isShared) else { return }
        closeTab(id: tab.id)
    }

    /// How many items a sidebar row should report.
    func sharedCount(for section: SharedSection) -> Int {
        switch section {
        case .systemPrompt: return systemPrompt.enabled ? 1 : 0
        case .skills:       return sharedSkills.count
        case .agents:       return registry.agents.count
        case .connectors:   return sharedConnectors.count
        case .automations:  return sharedAutomations.count
        }
    }

    /// Install every connector that needs it, then write the collection into
    /// every agent that can take it.
    ///
    /// The order is not incidental. Binding a connector whose binary does not
    /// exist yet registers an MCP server that cannot start, and the agent then
    /// reports a connection failure rather than a missing install — which is a
    /// far harder thing to diagnose from the agent's side.
    // MARK: - The shared system prompt

    /// Re-read the source of truth from disk.
    func refreshSystemPrompt() {
        systemPrompt = SystemPromptStore(paths: sandbox.paths).load()
    }

    /// Write the source of truth. Binding is explicit — "Apply to all agents".
    func saveSystemPrompt(body: String) {
        do {
            systemPrompt = try SystemPromptStore(paths: sandbox.paths)
                .save(SystemPrompt(body: body, enabled: systemPrompt.enabled))
            systemPromptStatus = sandbox.paths.display(sandbox.paths.sharedSystemPrompt)
        } catch {
            systemPromptStatus = "Could not save: \(error)"
        }
    }

    func setSystemPromptEnabled(_ enabled: Bool) {
        do {
            systemPrompt = try SystemPromptStore(paths: sandbox.paths)
                .save(SystemPrompt(body: systemPrompt.body, enabled: enabled))
            systemPromptStatus = enabled ? "Prompt is on — apply to push it to agents."
                                         : "Prompt is off."
        } catch {
            systemPromptStatus = "Could not save: \(error)"
        }
    }

    /// Write the prompt into every agent's instruction file.
    func bindSystemPrompt() {
        do {
            let reports = try SystemPromptStore.bind(
                prompt: systemPrompt,
                agents: registry.agents,
                paths: sandbox.paths
            )
            systemPromptStatus = reports.map(\.summary).joined(separator: "\n")
        } catch {
            systemPromptStatus = "Could not bind: \(error)"
        }
    }

    func bindShared() {
        guard !isBindingShared else { return }
        isBindingShared = true
        sharedStatus = "Installing shared connectors…"

        let sandbox = self.sandbox
        let connectors = sharedConnectors
        let skills = sharedSkills
        let agents = registry.agents
        let paths = sandbox.paths
        let prompt = systemPrompt

        Task.detached(priority: .userInitiated) {
            let installs = ConnectorBinder.installShared(
                connectors: connectors,
                sandbox: sandbox,
                onProgress: { _, message in
                    Task { @MainActor in self.sharedStatus = message }
                }
            )

            var collected: [String] = []
            for outcome in installs where !outcome.succeeded {
                collected.append("\(outcome.agentName): "
                    + (outcome.failureMessage ?? "the shared install failed"))
            }

            do {
                for report in try SkillBinder.apply(
                    skills: skills,
                    agents: agents,
                    paths: paths
                ) {
                    collected.append(report.summary)
                    collected.append(contentsOf: report.notes.map { "      \($0)" })
                }
                for report in try ConnectorBinder.apply(
                    connectors: connectors,
                    agents: agents,
                    paths: paths
                ) {
                    collected.append(report.summary)
                    collected.append(contentsOf: report.notes.map { "      \($0)" })
                }
                // The shared system prompt rides the same Apply: one button,
                // the whole collection. It is bound even when disabled — that
                // is what *clears* a stale block out of the agents' files.
                for report in try SystemPromptStore.bind(
                    prompt: prompt,
                    agents: agents,
                    paths: paths
                ) {
                    collected.append(report.summary)
                    collected.append(contentsOf: report.notes.map { "      \($0)" })
                }
            } catch {
                collected.append("binding stopped: \(error)")
            }

            // Bound to a `let` before the hop back: a `var` captured into
            // `MainActor.run` is a data race the compiler can only warn about
            // today, and an error under the Swift 6 language mode.
            let lines = collected

            await MainActor.run {
                self.sharedReports = lines
                self.isBindingShared = false
                self.sharedStatus = "Applied to \(agents.count) agents."
                self.refreshInstalledAgents()
            }
        }
    }

    /// Take the collection back out of every agent's files.
    func revertShared() {
        guard !isBindingShared else { return }
        do {
            var lines = try SkillBinder.revert(agents: registry.agents, paths: sandbox.paths)
            lines.append(contentsOf: try ConnectorBinder.revert(
                agents: registry.agents,
                paths: sandbox.paths
            ))
            sharedReports = lines.isEmpty ? ["Nothing was bound."] : lines
            sharedStatus = "Unbound. The collection's contents are untouched."
        } catch {
            sharedStatus = "Could not unbind: \(error)"
        }
    }

    /// A slug that is not already taken.
    ///
    /// `writeSkill` overwrites by id, so adding "Release checklist" twice would
    /// silently replace the first one. Suffixing is the least surprising fix:
    /// the second skill gets its own file and nothing is lost.
    private func uniqueID(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    // MARK: Skills

    func addSkill(name: String, summary: String, body: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let skill = Skill(
            id: uniqueID(
                Identifier.slug(trimmed, fallback: "skill"),
                taken: Set(sharedSkills.map(\.id))
            ),
            name: trimmed,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body
        )

        do {
            try sharedStore.writeSkill(skill)
            refreshShared()
            sharedStatus = "Added \(skill.name). Apply it to the agents when you are ready."
        } catch {
            banner = "Could not write the skill: \(error)"
        }
    }

    func setSkillEnabled(id: String, enabled: Bool) {
        do {
            try sharedStore.setSkillEnabled(id: id, enabled: enabled)
            refreshShared()
        } catch {
            banner = "Could not update the skill: \(error)"
        }
    }

    func removeSkill(id: String) {
        // `removeSkill` refuses an id that is not a safe path component, and it
        // throws *before* it takes the skill out of the list. `try?` therefore
        // discarded the only evidence, and the line below then announced a
        // removal that had not happened — the skill was still in the sidebar
        // under a status reading "Removed".
        do {
            try sharedStore.removeSkill(id: id)
        } catch {
            sharedStatus = "Could not remove \(id): \(error.localizedDescription)"
            return
        }
        refreshShared()
        sharedStatus = "Removed \(id). Its text is still in each agent's file "
            + "until you apply again."
    }

    // MARK: Connectors

    func addConnector(_ connector: Connector) {
        if let problem = connector.validationError {
            banner = problem
            return
        }
        do {
            try sharedStore.writeConnector(connector)
            refreshShared()
            sharedStatus = "Registered \(connector.name)."
        } catch {
            // `localizedDescription` rather than `"\(error)"`. Every refusal the
            // store throws is an enum with a written-out `errorDescription`, and
            // interpolation prints the case name and its labels instead — so a
            // refused credential would arrive as `inlinedCredential(id:
            // "github", findings: [...])` rather than as the sentence written
            // for exactly this moment.
            banner = "Could not write the connector: \(error.localizedDescription)"
        }
    }

    /// The counterpart of `setSkillEnabled`: a setter, not a re-registration.
    ///
    /// This used to mutate the connector and hand it straight back to
    /// `addConnector`, which had two consequences worth naming. That method
    /// validates, so an incomplete connector could never be switched *off* —
    /// the one action that would stop it being bound. And it reports
    /// "Registered …", so every toggle claimed to have just registered the
    /// connector it was switching.
    func setConnectorEnabled(id: String, enabled: Bool) {
        do {
            try sharedStore.setConnectorEnabled(id: id, enabled: enabled)
            refreshShared()
        } catch {
            banner = "Could not update the connector: \(error)"
        }
    }

    func removeConnector(id: String) {
        // Same shape as `removeSkill`: a refusal here arrives before the list is
        // touched, so the "Removed" line below used to report a removal that
        // had not happened.
        do {
            try sharedStore.removeConnector(id: id)
        } catch {
            sharedStatus = "Could not remove \(id): \(error.localizedDescription)"
            return
        }
        refreshShared()
        sharedStatus = "Removed \(id). It stays in each agent's MCP config "
            + "until you apply again."
    }

    // MARK: Automations

    func addAutomation(_ automation: Automation) {
        do {
            try sharedStore.writeAutomation(automation)
            refreshShared()
            sharedStatus = "Registered \(automation.name) — \(automation.schedule.summary)."
        } catch {
            banner = "Could not write the automation: \(error)"
        }
    }

    /// The counterpart of `setConnectorEnabled` — see the note there for why
    /// this is a setter rather than a re-add.
    func setAutomationEnabled(id: String, enabled: Bool) {
        do {
            try sharedStore.setAutomationEnabled(id: id, enabled: enabled)
            refreshShared()
        } catch {
            banner = "Could not update the automation: \(error)"
        }
    }

    func removeAutomation(id: String) {
        do {
            try sharedStore.removeAutomation(id: id)
        } catch {
            sharedStatus = "Could not remove \(id): \(error.localizedDescription)"
            return
        }
        refreshShared()
    }

    /// Run one automation now, schedule or not.
    func runAutomation(id: String) {
        guard let automation = sharedAutomations.first(where: { $0.id == id }) else { return }
        run(automations: [automation], label: automation.name)
    }

    /// Run everything the schedule says is due.
    func runDueAutomations() {
        let due = AutomationRunner.due(automations: sharedAutomations)
        guard !due.isEmpty else {
            sharedStatus = "Nothing is due right now."
            return
        }
        run(automations: due, label: "\(due.count) automation\(due.count == 1 ? "" : "s")")
    }

    /// The one place automations are actually started.
    ///
    /// Off the main actor because this launches a real agent and waits for it,
    /// which on a slow prompt is minutes — inline it would freeze the window
    /// with no way to tell a slow run from a hung one.
    private func run(automations: [Automation], label: String) {
        let sandbox = self.sandbox
        let agents = registry.agents
        let knownWorkspaces = workspaces
        let store = sharedStore

        sharedStatus = "Running \(label)…"

        Task.detached(priority: .userInitiated) {
            var collected: [String] = []
            for automation in automations {
                let result = AutomationRunner.run(
                    automation,
                    agents: agents,
                    workspaces: knownWorkspaces,
                    sandbox: sandbox,
                    store: store
                )
                collected.append(result.summary)
            }
            // Bound to a `let` before the hop back: a `var` captured into
            // `MainActor.run` is a data race the compiler only warns about
            // today, and an error under the Swift 6 language mode.
            let lines = collected

            await MainActor.run {
                self.refreshShared()
                self.sharedStatus = lines.joined(separator: "\n")
            }
        }
    }

    // MARK: - Local models (pillar 03)

    var selectedLocalModel: LocalModel? {
        guard let selectedModelID else { return nil }
        return modelScan?.models.first { $0.id == selectedModelID }
    }

    /// Where the app looked, for the "not found" explanation.
    ///
    /// Stored, not computed. `diagnostics()` descends into bundled application
    /// directories looking for a binary that usually is not there, and reading
    /// it from a view's `body` ran that walk on the main actor on every single
    /// evaluation — several times a second for as long as the pane was open.
    @Published var runtimeDiagnostics: [(path: URL, origin: LlamaRuntime.Origin, exists: Bool)] = []

    /// Look for `llama-server`, and record where the search looked.
    ///
    /// Both halves run off the main actor. The search is filesystem work rather
    /// than a property read, and it is the same work the diagnostics need, so
    /// it is done once here instead of once per view evaluation.
    func refreshRuntime() async {
        let paths = sandbox.paths
        typealias Probe = (
            LlamaRuntime?,
            [(path: URL, origin: LlamaRuntime.Origin, exists: Bool)],
            LlamaServerCapabilities
        )
        // The capabilities probe is part of the same detached job rather than a
        // second one: it runs the binary with `--help`, and both the plan and the
        // one-router section need the answer.
        let probe: Probe = await Task.detached(priority: .utility) {
            let locator = LlamaRuntimeLocator(paths: paths)
            return (locator.locate(), locator.diagnostics(), locator.capabilities())
        }.value
        llamaRuntime = probe.0
        runtimeDiagnostics = probe.1
        serverCapabilities = probe.2
        rebuildServingPolicy()
    }

    /// Rebuild the one-router section from whatever is known right now.
    ///
    /// Called from both refreshes because its inputs move independently: the
    /// runtime refresh changes which binary is installed, and the lifecycle
    /// refresh changes which servers are running — and a server in llama-server's
    /// own router mode is the one state the section reports about the machine
    /// rather than about the code.
    func rebuildServingPolicy() {
        servingPolicyText = ModelLifecycleReport.servingPolicy(
            lifecycleStore,
            capabilities: serverCapabilities,
            foreignServers: foreignServers
        )
    }

    /// Scan the configured directories for GGUF models.
    ///
    /// Runs off the main actor because reading a model card costs a few hundred
    /// milliseconds each, and a library of a dozen models would freeze the window
    /// for seconds if this ran inline.
    func scanModels() {
        let roots = modelRoots.map { URL(fileURLWithPath: $0) }
        guard !roots.isEmpty else {
            modelStatus = "No model directory configured."
            return
        }

        isScanningModels = true
        modelStatus = "Scanning \(roots.count) director\(roots.count == 1 ? "y" : "ies")…"

        Task.detached(priority: .userInitiated) {
            let scan = ModelScanner().scan(roots: roots)
            await MainActor.run {
                self.modelScan = scan
                self.isScanningModels = false
                self.modelStatus = "\(scan.totalModels) model\(scan.totalModels == 1 ? "" : "s"), "
                    + "\(scan.visionModels) with vision."

                // Keep the selection if it survived the rescan, otherwise fall
                // back to the first model so the pane is never blank.
                if let current = self.selectedModelID,
                   scan.models.contains(where: { $0.id == current }) {
                    self.recomputePlan()
                } else if let first = scan.models.first {
                    self.selectLocalModel(id: first.id)
                } else {
                    self.selectedModelID = nil
                    self.modelPlan = nil
                }
            }
        }
    }

    func addModelRoot(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !modelRoots.contains(expanded) else { return }
        modelRoots.append(expanded)
        persistModelRoots()
        scanModels()
    }

    func removeModelRoot(_ path: String) {
        modelRoots.removeAll { $0 == path }
        persistModelRoots()
        scanModels()
    }

    func selectLocalModel(id: String) {
        selectedModelID = id
        recomputePlan()
    }

    /// Recompute the plan for the selected model under the current policies.
    func recomputePlan() {
        guard let model = selectedLocalModel else {
            modelPlan = nil
            return
        }
        let optimizer = ModelOptimizer(
            hardware: .current(),
            policy: memoryPolicy,
            cachePolicy: cachePolicy,
            sampling: sampling,
            // Memoised, so dragging a policy slider does not launch a
            // `llama-server --help` per keystroke.
            capabilities: LlamaRuntimeLocator(paths: sandbox.paths).capabilities()
        )
        do {
            modelPlan = try optimizer.plan(for: model)
        } catch {
            modelPlan = nil
            modelStatus = "\(error)"
        }
    }

    func setMemoryPolicy(_ policy: MemoryPolicy) {
        memoryPolicy = policy
        recomputePlan()
    }

    func setCachePolicy(_ policy: CachePolicy) {
        cachePolicy = policy
        recomputePlan()
    }

    // MARK: Serving

    var isServing: Bool { servedModelID != nil }

    /// The display name of whatever is loaded, for the toolbar and the footer.
    var servedModelName: String? {
        guard let servedModelID else { return nil }
        return modelScan?.models.first { $0.id == servedModelID }?.displayName
    }

    /// Start `llama-server` for the selected model.
    func startServingSelectedModel() async {
        guard let model = selectedLocalModel, let plan = modelPlan else { return }
        guard let runtime = llamaRuntime else {
            modelStatus = "No llama-server found. See the runtime section below."
            return
        }
        guard let port = PortAllocator.firstFree(from: 8_080) else {
            modelStatus = "No free port at or above 8080."
            return
        }

        await stopServing()

        let slug = model.model.filename
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let logURL = sandbox.paths.logs.appendingPathComponent("llama-server-\(slug).log")

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: port,
                logURL: logURL
            ),
            paths: sandbox.paths
        )
        llamaServer = server
        serverHealth = .loading
        serverDeathLog = nil
        healthFailures = 0

        // Warned rather than acted on, but warned *before* the load: a Metal
        // allocation failure minutes into a multi-gigabyte load is the worst
        // possible moment to discover another server is holding the memory.
        let conflicts = await conflictingServers()
        modelStatus = conflicts.isEmpty
            ? "Loading \(model.displayName)…"
            : "Loading \(model.displayName)… \(conflicts.count) other llama-server "
                + "process(es) are already running and sharing unified memory with it."

        do {
            try await server.start()
            servedModelID = model.id
            servedPort = port
            modelStatus = "Serving \(model.displayName) on port \(port)."
            serverHealth = .healthy
            lastHealthCheck = Date()
            startHealthPolling()

            // Now that it is up, ask it what it actually loaded. The plan was a
            // prediction from the GGUF header; this is the server's own answer,
            // and the only thing that can contradict it. A template that
            // resolves but cannot call tools is invisible without this.
            servedProps = await server.props()
            servedDisagreements = await server.disagreementsWithPlan()

            // And then the only question none of the above can answer: not
            // what the template advertises, but whether the model uses it.
            // Run automatically because a user who has to press a button to
            // find out whether their agent will work will find out the hard
            // way instead.
            servedToolProbe = await probeTools(against: server)
        } catch {
            // The error already carries the server's own log tail, which is the
            // only thing that explains a failed load.
            modelStatus = "\(error)"
            serverHealth = .idle
            llamaServer = nil
            servedModelID = nil
            servedPort = nil
            servedProps = nil
            servedDisagreements = []
            servedToolProbe = nil
        }
    }

    /// Stop the server and release its memory and port.
    ///
    /// Async, because the stop is not instant. `llama-server` unloads a
    /// multi-gigabyte model on SIGTERM and the wait lasts as long as that
    /// takes — up to ten seconds. On the main actor that was a frozen window
    /// for precisely the period in which the user was waiting to be told the
    /// stop had worked.
    func stopServing() async {
        stopHealthPolling()
        let server = llamaServer
        await Task.detached(priority: .userInitiated) { server?.stop() }.value
        tearDownServing()
    }

    /// Forget the served model and everything recorded about it.
    ///
    /// Split out of `stopServing()` because quitting cannot call that: teardown
    /// at exit has to finish on the thread that is already running, and this is
    /// the half that is safe to do there.
    private func tearDownServing() {
        llamaServer = nil
        servedModelID = nil
        servedPort = nil
        servedProps = nil
        servedDisagreements = []
        servedToolProbe = nil
        isProbingTools = false
        serverHealth = .idle
        lastHealthCheck = nil
        healthFailures = 0
        serverDeathLog = nil
        if case .some = modelStatus, modelStatus?.hasPrefix("Serving") == true {
            modelStatus = "Stopped."
        }
    }

    /// Tear down everything that would otherwise outlive the process.
    ///
    /// Called on the way out of the app. Without it, closing the window exited
    /// with the served model still holding its memory and its port, and with
    /// every agent's pty still running: `stopServing()` was reachable only from
    /// the Models pane, `TabItem.terminate()` only from `closeTab`, and
    /// `PTYSession.deinit` deliberately does not kill.
    func shutdown() {
        stopHealthPolling()
        // Synchronous, and on this thread, deliberately. `applicationWillTerminate`
        // is called once and the process exits as soon as it returns, so a task
        // started here would never run and the server would outlive the app.
        // Blocking during quit is the correct trade; blocking while the window
        // is on screen is not, which is why `stopServing()` is async.
        llamaServer?.stop()
        tearDownServing()
        // Synchronous, for the same reason as the line above: a task started in
        // `applicationWillTerminate` never runs, and a model loaded by an alias
        // would outlive the app holding gigabytes and a port.
        modelSupervisor.stopSweeping()
        modelSupervisor.stopAllBlocking()
        for tab in tabs {
            tab.terminate()
        }
        tabs.removeAll()
    }


    // MARK: - Model lifecycle (track 1.3)

    /// Re-read the alias table from disk, and re-state what is loaded.
    ///
    /// The file is shared with `jxcode local`, so it can have changed under us
    /// between two appearances of the pane. Re-reading is cheap — one small JSON
    /// file — and a stale alias table is the exact failure this feature exists
    /// to remove, so it is re-read rather than cached.
    func reloadLifecycle() {
        lifecycleStore.load()
        runningModels = modelSupervisor.running()
    }

    /// Start the idle sweep. A no-op when one is already running.
    func startLifecycle() {
        modelSupervisor.startSweeping()
    }

    func bindAlias(name: String, path: String, idleTimeout: TimeInterval?) {
        do {
            try lifecycleStore.setAlias(ModelAlias(
                name: name,
                modelPath: path,
                idleTimeout: idleTimeout
            ))
            lifecycleStatus = "'\(name)' now resolves to "
                + (path as NSString).expandingTildeInPath
            reloadLifecycle()
        } catch {
            // `errorDescription` rather than `"\(error)"`: every one of these is
            // an enum with a sentence written for exactly this moment, and
            // reflection would print the case name and its labels instead.
            lifecycleStatus = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func unbindAlias(_ name: String) {
        do {
            let removed = try lifecycleStore.removeAlias(named: name)
            lifecycleStatus = removed
                ? "'\(name)' unbound."
                : "'\(name)' was not bound in profile '\(lifecycleStore.activeProfile.name)'."
            reloadLifecycle()
        } catch {
            lifecycleStatus = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func selectProfile(_ name: String) {
        do {
            try lifecycleStore.selectProfile(named: name)
            reloadLifecycle()
            let aliases = lifecycleStore.knownAliases
            lifecycleStatus = "profile '\(name)' is active — "
                + (aliases.isEmpty
                    ? "it binds nothing, so no alias resolves through it."
                    : "\(aliases.joined(separator: ", ")) resolve through it.")
        } catch {
            lifecycleStatus = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func setProfileIdleTimeout(_ seconds: TimeInterval) {
        do {
            try lifecycleStore.setIdleTimeout(seconds)
            reloadLifecycle()
        } catch {
            lifecycleStatus = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Load an alias now, without waiting for a request.
    ///
    /// The ordinary path needs no button — the router starts a model when a
    /// request names its alias — but a user who wants to see it load, or to
    /// have it warm before an agent asks, needs one.
    func startAlias(_ name: String) async {
        lifecycleStatus = "loading '\(name)'…"
        do {
            _ = try await modelSupervisor.start(alias: name)
            await refreshLifecycle()
        } catch {
            lifecycleStatus = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func stopAlias(_ name: String) async {
        let stopped = await modelSupervisor.stop(alias: name)
        lifecycleStatus = stopped ? "'\(name)' unloaded." : "'\(name)' was not loaded."
        await refreshLifecycle()
    }

    /// Run the idle sweep once, now.
    ///
    /// The timer is a convenience, not the mechanism: a laptop that sleeps fires
    /// no timers, and a user looking at a pane that says "idle — due to unload"
    /// should not have to wait for one. Same call the timer makes.
    func sweepNow() async {
        let stopped = await modelSupervisor.sweep()
        lifecycleStatus = stopped.isEmpty
            ? "nothing was due to unload"
            : "unloaded \(stopped.joined(separator: ", "))"
        await refreshLifecycle()
    }

    /// Ask every loaded server how it is, read its counters, and re-read the log.
    /// The tail of the running model server's log.
    ///
    /// Stored, not computed. Reading it used to open the log file, seek to the
    /// end and pull 16 KB — and the Models pane reads this value twice from
    /// its own `body`, once to decide whether to show the section and once to
    /// draw it. So every redraw of the window read 32 KB off disk, on the main
    /// thread, to produce a string it then threw away and re-read on the next
    /// redraw.
    ///
    /// It is refreshed by `refreshLifecycle()`, which the pane already calls
    /// every five seconds. The log is a tail for watching a server start; a
    /// five-second-old tail is what it was showing anyway.
    @Published private(set) var llamaLogTail: String = ""

    func refreshLifecycle() async {
        runningModels = modelSupervisor.running()
        llamaLogTail = llamaServer?.logTail() ?? ""

        var health: [String: ServerHealth] = [:]
        var metrics: [String: ServerMetricsReport] = [:]
        for model in runningModels {
            health[model.alias] = await modelSupervisor.health(alias: model.alias)
            metrics[model.alias] = await modelSupervisor.metrics(alias: model.alias)
        }
        lifecycleHealth = health
        lifecycleMetrics = metrics

        // Servers this app did not start. A supervisor's registry lives in the
        // process that made it, so without this the pane shows an empty list
        // beside three models that are plainly running.
        foreignServers = ModelLifecycleReport.runningElsewhere(
            await RunningServers.list(),
            store: lifecycleStore
        )

        // After `foreignServers`, not before: the one-router section reports
        // whether anything on this machine is in router mode, and that is what
        // the list above just answered.
        rebuildServingPolicy()

        refreshLogStream()
    }

    /// Re-read the tail of the selected stream.
    func refreshLogStream() {
        logStreamTail = ModelLogs(paths: sandbox.paths).tail(logStream, alias: logStreamAlias)
    }

    /// The aliases the active profile binds.
    var boundAliases: [ModelAlias] { lifecycleStore.activeProfile.aliases }

    var knownProfileNames: [String] { lifecycleStore.knownProfileNames }

    var activeProfileName: String { lifecycleStore.activeProfile.name }

    var activeProfileIdleTimeout: TimeInterval { lifecycleStore.activeProfile.idleTimeout }

    /// The idle timeout an alias will actually be unloaded on.
    func effectiveIdleTimeout(_ alias: ModelAlias) -> TimeInterval {
        ModelLifecycleReport.effectiveIdle(alias, in: lifecycleStore.activeProfile)
    }

    // MARK: - Is it still running?

    /// How often the running server is asked whether it is still there.
    ///
    /// Often enough that a dead model is noticed while the user is still at the
    /// window; not so often that the check competes with generation.
    static let healthPollInterval: TimeInterval = 5

    /// Poll for as long as a server is supposed to be running.
    ///
    /// This exists because `isServing` is a flag set once at launch and never
    /// revisited. Without it, a server that dies in the third minute still
    /// reports as loaded in the thirtieth — which is worse than reporting
    /// nothing, because the user acts on it.
    private func startHealthPolling() {
        stopHealthPolling()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.pollServerHealth()
            }
        }
    }

    private func stopHealthPolling() {
        healthTask?.cancel()
        healthTask = nil
    }

    /// One poll. Separate from the loop so a manual refresh can reuse it.
    func pollServerHealth() async {
        guard let server = llamaServer else { return }

        // Process liveness first. A process that has exited can never answer,
        // so checking the network first would report "not responding" and the
        // UI would wait forever for a recovery that cannot happen.
        guard server.isProcessAlive else {
            // Capture the log now: it is the only record of why it died, and
            // it is gone once the process is reaped.
            serverDeathLog = server.logTail()
            healthFailures += 1
            lastHealthCheck = Date()
            serverHealth = .exited
            return
        }

        let ok = await server.checkHealth()
        lastHealthCheck = Date()

        if ok {
            healthFailures = 0
            serverHealth = .healthy
            return
        }

        healthFailures += 1
        // A long generation blocks the health endpoint. Calling the model dead
        // on the first missed poll would be wrong more often than right.
        if healthFailures >= 3 {
            serverHealth = .unreachable
        }
    }

    /// How long since the last check, for "checked 4s ago".
    var secondsSinceHealthCheck: Int? {
        guard let lastHealthCheck else { return nil }
        return Int(Date().timeIntervalSince(lastHealthCheck))
    }

    /// Other `llama-server` processes already holding unified memory.
    ///
    /// Why they are reported rather than terminated is spelled out in
    /// `RunningServers`, next to the listing itself.
    nonisolated func conflictingServers(excluding pid: Int32 = 0) async -> [String] {
        await RunningServers.list()
            .filter { $0.pid != pid }
            .map(\.command)
    }

    /// Re-read the running server's own report, for the refresh button.
    func refreshServedProps() async {
        guard let server = llamaServer else { return }
        servedProps = await server.props()
        servedDisagreements = await server.disagreementsWithPlan()
    }

    /// Run the live tool-calling probe against the running server.
    ///
    /// Separate from `refreshServedProps` because it costs a generation. That
    /// is cheap — 512 tokens, greedy — but it is not free, and folding it into
    /// a button labelled "ask the server again" would make the cheap action
    /// expensive without saying so.
    func refreshToolProbe() async {
        guard let server = llamaServer else { return }
        servedToolProbe = await probeTools(against: server)
    }

    /// Ask a running llama-server to call a tool.
    ///
    /// The model name is the plan's own path, because that is exactly what
    /// llama-server reports from `/v1/models` and accepts on a request — so the
    /// probe asks for the model the user actually loaded rather than a name
    /// that happens to be nearby.
    private func probeTools(against server: LlamaServer) async -> ToolProbe.Outcome {
        isProbingTools = true
        defer { isProbingTools = false }

        let provider = Provider(name: "served", kind: .localGGUF, baseURL: server.baseURL)
        // The plan is where this server's configuration is written down, and the
        // probe has to ask in that environment rather than in a bare client's.
        // `templateKwargs` is nil on a build where the server itself was told to
        // reason, which is the honest answer: the environment is then carried by
        // the server's own flags and not by anything the request says.
        return await ToolProbe(
            templateKwargs: server.configuration.plan.templateKwargs
        ).run(
            provider: provider,
            model: server.configuration.plan.modelPath
        )
    }

    /// Start the router and wait until it is genuinely listening.
    ///
    /// `startRouter` binds on a background queue and reports back later, so
    /// calling it and immediately binding agents would aim them at a port that
    /// is not open yet.
    private func startRouterAndWait(timeout: TimeInterval = 10) async {
        startRouter()
        let deadline = Date().addingTimeInterval(timeout)
        while !routerRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// How many agents are actually pointed at the router.
    ///
    /// `isRouted`, not "anything but `.notApplicable`": a refused bind wrote
    /// nothing, so the agent still points wherever it did before and counting it
    /// here would claim a routing that never happened.
    var boundAgentCount: Int {
        bindReports.filter(\.isRouted).count
    }

    // MARK: - One-click activation

    /// The last activation, as a list of steps with a remedy on each failure.
    ///
    /// `nil` until one has been run. The panes render this instead of a status
    /// sentence, because the thing that was missing was not a message — it was
    /// *which hop* was not standing and what to do about it.
    @Published var activationReport: ActivationReport?
    @Published var isActivating = false

    /// Take a backend the whole way to the agents in one press.
    ///
    /// The sequence, the wording and the remedies all live in
    /// `RoutingActivation`, so `jxcode activate` and this button cannot describe
    /// different outcomes. Everything here is the wiring: which object to ask
    /// for each step, and which published field to mirror it into.
    func activateRouting(source: ActivationSource) async {
        guard !isActivating else { return }
        isActivating = true
        activationReport = nil
        defer { isActivating = false }

        let handles = ActivationHandles(
            serveLocal: { [weak self] source in
                guard let self else { throw ActivationRefusal("the app is shutting down") }
                return try await self.serveForActivation(source)
            },
            providers: { [weak self] in
                await MainActor.run { self?.providerStore.providers ?? [] }
            },
            register: { [weak self] provider in
                guard let self else { throw ActivationRefusal("the app is shutting down") }
                try await MainActor.run {
                    try self.providerStore.add(provider)
                    self.refreshProviders()
                }
                return provider
            },
            startRouter: { [weak self] provider, model, port in
                guard let self else { throw ActivationRefusal("the app is shutting down") }
                return try await self.pointRouter(at: provider, model: model, port: port)
            },
            bind: { [weak self] base, model in
                guard let self else { throw ActivationRefusal("the app is shutting down") }
                return try self.writeAgentConfigs(routerURL: base, model: model)
            },
            probeModels: { provider in
                try await ModelCatalog().probe(provider).models
            },
            auth: { [weak self] in
                await MainActor.run { self?.routerAuth ?? RouterAuth() }
            }
        )

        let report = await RoutingActivation.run(
            ActivationRequest(source: source, port: routerPort),
            handles: handles
        )

        activationReport = report
        providerStatus = report.headline
        refreshRouterLog()
    }

    /// Take the selected local model the whole way to the agents.
    ///
    /// Kept as a named entry point rather than folded into the pane, because the
    /// CLI's `jxcode activate` runs the same chain — see `RoutingActivation`.
    func activateSelectedLocalModel() async {
        guard let model = selectedLocalModel else {
            activationReport = .refused(
                source: "no model",
                reason: "no local model is selected",
                remedy: "Pick one in the Library above — or add the folder holding your "
                    + ".gguf files if the list is empty."
            )
            return
        }
        await activateRouting(source: .localModel(
            path: model.model.url.path,
            memory: memoryPolicy,
            cache: cachePolicy,
            sampling: sampling
        ))
    }

    /// The registered-backend half.
    func activateSelectedBackend() async {
        guard let provider = selectedProvider else {
            activationReport = .refused(
                source: "no backend",
                reason: "no backend is selected",
                remedy: "Add one above: a base URL, a kind, and a key if it is a hosted API."
            )
            return
        }
        await activateRouting(source: .registered(id: provider.id, model: selectedModel))
    }

    // MARK: - Proving the route

    /// The last route proof, or nil until one has been run.
    ///
    /// Kept apart from `activationReport` because it answers a different
    /// question. Activation asks "did a request get through"; this asks "did it
    /// get through the route it was supposed to". A router that translated when
    /// it should have proxied passes the first and fails the second, and no
    /// client can tell — both produce a perfectly good Anthropic answer.
    @Published var routeProofReport: RouteProofReport?
    @Published var isProvingRoute = false

    /// Prove every route against a recording backend.
    ///
    /// Deliberately does not touch the configured backend: it stands up its own
    /// listener on loopback, so pressing this costs nothing and cannot be
    /// mistaken for a test of the provider the user is paying for. The work
    /// itself is `RouteProof`, which is the same code `jxcode prove route`
    /// runs — a second implementation here would be a second set of claims to
    /// keep true.
    func proveRoutes() async {
        guard !isProvingRoute else { return }
        isProvingRoute = true
        routeProofReport = nil
        defer { isProvingRoute = false }
        routeProofReport = await RouteProof.run()
        refreshRouterLog()
    }

    /// Load the selected GGUF, and describe it the way the chain expects.
    ///
    /// Selecting by *path* rather than trusting the current selection matters:
    /// the chain is given a path, and the pane may have moved on since. The two
    /// disagreeing would serve one model and register another.
    private func serveForActivation(_ source: ActivationSource) async throws -> ServedLocalModel {
        guard case .localModel(let path, let memory, let cache, let sampling) = source else {
            throw ActivationRefusal("the local path was asked to serve a registered backend")
        }

        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard let model = modelScan?.models.first(where: {
            $0.model.url.standardizedFileURL == target
                || $0.model.resolvedURL?.standardizedFileURL == target
        }) else {
            throw ActivationRefusal(
                "\(target.lastPathComponent) is not in the current scan — press Rescan in the "
                    + "Library and try again."
            )
        }

        // Apply the policies the request carried. The pane writes these as the
        // user changes them, but Activate can be pressed from a state where the
        // plan is stale.
        if memoryPolicy != memory { memoryPolicy = memory }
        if cachePolicy != cache { cachePolicy = cache }
        if self.sampling != sampling { setSampling(sampling) }

        if selectedModelID != model.id { selectLocalModel(id: model.id) }

        // A second load of the same model is wasted work and a second copy of
        // several gigabytes in unified memory, so an already-healthy server for
        // this exact model is reused.
        if servedModelID == model.id, serverHealth == .healthy, let port = servedPort {
            return ServedLocalModel(
                displayName: model.displayName,
                filename: model.model.filename,
                port: port,
                contextLength: servedServerContext ?? modelPlan?.contextLength,
                warnings: await activationWarnings()
            )
        }

        await startServingSelectedModel()

        guard serverHealth == .healthy, let port = servedPort else {
            // `startServingSelectedModel` has already put the server's own log
            // tail into `modelStatus`, which is the only thing that explains a
            // failed load.
            throw ActivationRefusal(modelStatus ?? "the model did not load")
        }

        return ServedLocalModel(
            displayName: model.displayName,
            filename: model.model.filename,
            port: port,
            contextLength: servedServerContext ?? modelPlan?.contextLength,
            warnings: await activationWarnings()
        )
    }

    /// Things worth saying before a multi-gigabyte load, not worth stopping for.
    private func activationWarnings() async -> [String] {
        let conflicts = await conflictingServers()
        guard !conflicts.isEmpty else { return [] }
        return ["\(conflicts.count) other llama-server process(es) are running and share "
            + "unified memory with this one."]
    }

    /// Point the live router at a backend, restarting it only if the port moved.
    ///
    /// The router reads its configuration per request, so switching backend or
    /// model needs no restart — which is the whole reason `RouterState` exists.
    /// A *port* change is the one thing it cannot absorb.
    private func pointRouter(at provider: Provider, model: String, port: UInt16) async throws -> String {
        selectedProviderID = provider.id
        selectedModel = model

        if routerRunning, routerPort != port {
            stopRouter()
        }
        routerPort = port
        pushRouterConfiguration()

        if !routerRunning {
            await startRouterAndWait()
        }
        guard routerRunning else {
            throw ActivationRefusal(
                providerStatus ?? "the router did not start on port \(port)"
            )
        }
        return router.baseURL
    }

    /// The same write `bindAgents()` performs, returning the reports instead of
    /// only publishing them, so the chain can say how many agents it reached.
    private func writeAgentConfigs(
        routerURL: String,
        model: String
    ) throws -> [AgentConfigWriter.Report] {
        let reports = try AgentConfigWriter.apply(
            agents: registry.agents,
            paths: sandbox.paths,
            routerURL: routerURL,
            model: model,
            token: agentRouterToken,
            overrides: agentModelOverrides,
            wires: agentWireOverrides,
            contextLength: routingContextLength
        )
        bindReports = reports
        return reports
    }

    // MARK: - Git state

    /// Git status per workspace.
    ///
    /// Read off the main actor and all at once rather than per row: a `git
    /// status` call costs tens of milliseconds, and a sidebar that shells out
    /// while drawing is a sidebar that stutters.
    @Published var gitStatuses: [UUID: GitStatus] = [:]
    @Published var isRefreshingGit = false

    func refreshGitStatuses() {
        let targets = workspaces.map { (id: $0.id, path: $0.path) }
        guard !targets.isEmpty else { return }

        // The sandbox environment, not the host's: `git` should be the one the
        // app's own PATH resolves, so what the user sees matches what an agent
        // would see in the same directory.
        let environment = sandbox.env(workspace: nil)
        isRefreshingGit = true

        Task.detached(priority: .utility) {
            var results: [UUID: GitStatus] = [:]
            for target in targets {
                results[target.id] = GitStatus.read(at: target.path, environment: environment)
            }
            let snapshot = results
            await MainActor.run {
                self.gitStatuses = snapshot
                self.isRefreshingGit = false
            }
        }
    }

    func gitStatus(for workspace: Workspace) -> GitStatus? {
        gitStatuses[workspace.id]
    }

    // MARK: - Adopting an existing directory

    @Published var showAdoptWorkspace = false
    @Published var adoptPath = ""
    @Published var adoptName = ""

    /// Open an existing directory as a workspace.
    ///
    /// The isolation this app provides is about the *toolchain*, not about
    /// hiding your code — so pointing a workspace at a real repository is the
    /// normal case, not an escape hatch. Nothing is copied or moved.
    func adoptWorkspace() {
        let raw = adoptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            banner = "\(expanded) is not a directory."
            return
        }

        // Default the name to the directory's own name, which is what the user
        // would have typed anyway.
        let name = adoptName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty
            ? URL(fileURLWithPath: expanded).lastPathComponent
            : name

        do {
            let workspace = try store.adopt(name: resolvedName, path: expanded)
            workspaces = store.workspaces
            selectedWorkspaceID = workspace.id
            // `WorkspaceStore.adopt` has already recorded the folder for the
            // sidebar's recent list — recording it again here would double the
            // visit count on every adopt, which is the sort of number that looks
            // like a bug the first time someone opens the same folder twice.
            refreshFolders()
            tabs = []
            selectedTabID = nil
            adoptPath = ""
            adoptName = ""
            showAdoptWorkspace = false
            refreshGitStatuses()
        } catch {
            banner = "Could not open that directory: \(error)"
        }
    }

    // MARK: - Custom agents

    @Published var showAddAgent = false
    @Published var newAgentName = ""
    @Published var newAgentCommand = ""
    @Published var newAgentArguments = ""
    @Published var newAgentInstallCommand = ""

    /// Register a CLI the built-in list does not know about.
    ///
    /// The registry has always supported this — it loads `agents.json` — but
    /// nothing exposed it, so the only way to add an agent was to hand-edit
    /// JSON. Since the app launches arbitrary CLIs, the list should not be a
    /// closed set.
    func addCustomAgent() {
        let name = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = newAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else {
            banner = "An agent needs both a name and a command."
            return
        }

        let arguments = newAgentArguments
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        let install = newAgentInstallCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = AgentDefinition(
            id: Self.slug(for: name),
            name: name,
            command: command,
            arguments: arguments,
            installCommand: install.isEmpty ? nil : install
        )

        do {
            try registry.add(agent)
            newAgentName = ""
            newAgentCommand = ""
            newAgentArguments = ""
            newAgentInstallCommand = ""
            showAddAgent = false
            refreshInstalledAgents()
            banner = "\(agent.name) registered. It runs inside the sandbox like the built-in agents."
        } catch {
            banner = "Could not register that agent: \(error)"
        }
    }

    /// A stable, filesystem- and JSON-safe id derived from the display name.
    static func slug(for name: String) -> String {
        Identifier.slug(name, fallback: "agent")
    }

    // MARK: - Router authentication

    @Published var routerAuth = RouterAuth()
    @Published var agentModelOverrides: [String: String] = [:]

    /// Per-agent wire, for the agents that have a wire to choose.
    ///
    /// Only a Codex config carries one (`wire_api`), and since February 2026 the
    /// only value a current Codex accepts is `responses`. The override exists
    /// for the two cases that still need it: a user pinned to an older Codex,
    /// and a backend whose Responses streaming is broken while its Chat
    /// Completions streaming works. Either way the choice is the user's, and
    /// `AgentConfigWriter` reports what it did rather than deciding silently.
    @Published var agentWireOverrides: [String: AgentWire] = [:]

    func loadRouterAuth() {
        routerAuth = RouterAuth.load(from: sandbox.paths)
        pushRouterAuth()
    }

    func setRouterAuthEnabled(_ enabled: Bool) {
        routerAuth.isEnabled = enabled
        if enabled, routerAuth.token?.isEmpty != false {
            routerAuth.token = RouterAuth.generateToken()
        }
        persistRouterAuth()
    }

    func regenerateRouterToken() {
        routerAuth.token = RouterAuth.generateToken()
        persistRouterAuth()
    }

    private func persistRouterAuth() {
        do {
            try routerAuth.save(to: sandbox.paths)
        } catch {
            providerStatus = "Could not save the router token: \(error)"
            return
        }
        pushRouterAuth()
        // Agents already bound need the new token, or they start getting 401s.
        if routerRunning { bindAgents() }
        // So do tabs launched from here on.
        //
        // The router's own policy changed the moment `pushRouterAuth()` ran,
        // but the sandbox still holds the token it was given when the router
        // *started* — usually the placeholder. Enabling auth on a running
        // router therefore left every subsequent tab presenting a credential
        // the router had already stopped accepting, and the 401 read as
        // routing being broken rather than as a token that did not follow.
        pushSandboxRouter()
    }

    private func pushRouterAuth() {
        routerState.update(auth: routerAuth)
    }

    /// The credential an agent presents to the router.
    ///
    /// With auth on this is the real token, without which the router answers
    /// 401 and the agent looks unrouted. With it off it is the placeholder,
    /// which keeps the written config byte-identical to what it was before
    /// auth existed — an agent still needs *something* in the credential slot,
    /// because Claude Code refuses to start with an empty one.
    var agentRouterToken: String {
        routerAuth.isEnabled
            ? (routerAuth.token ?? AgentConfigWriter.placeholderToken)
            : AgentConfigWriter.placeholderToken
    }

    /// Point the sandbox at the running router, carrying the current credential.
    ///
    /// The process environment and the agent config files are two separate
    /// places the token has to land, and they are not written together: this
    /// one covers tabs launched from the app, `bindAgents()` covers the files.
    /// A token that reaches only one of them is a router that rejects exactly
    /// half of what the user starts.
    private func pushSandboxRouter() {
        guard routerRunning else { return }
        sandbox.setRouter(url: router.baseURL, token: agentRouterToken)
    }

    // MARK: - Provider editing

    /// Replace a stored provider.
    ///
    /// Adding a provider was previously one-way: getting a key wrong meant
    /// deleting the entry and retyping everything.
    func updateProvider(_ provider: Provider) {
        do {
            try providerStore.add(provider)
            providers = providerStore.providers
            pushRouterConfiguration()
        } catch {
            providerStatus = "Could not save the provider: \(error)"
        }
    }

    func setModelOverride(agentID: String, model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            agentModelOverrides[agentID] = trimmed
        } else {
            agentModelOverrides.removeValue(forKey: agentID)
        }
    }

    /// Set, change or clear one agent's wire. `nil` restores the default.
    func setWireOverride(agentID: String, wire: AgentWire?) {
        if let wire {
            agentWireOverrides[agentID] = wire
        } else {
            agentWireOverrides.removeValue(forKey: agentID)
        }
    }

    /// The provider currently being edited, if any.
    ///
    /// Held as a draft rather than mutated in place: a half-typed base URL
    /// should not be pushed to the router on every keystroke.
    @Published var providerDraft: Provider?
    @Published var showEditProvider = false

    func beginEditingProvider(_ provider: Provider) {
        providerDraft = provider
        showEditProvider = true
    }

    func commitProviderDraft() {
        guard let draft = providerDraft else { return }
        updateProvider(draft)
        providerDraft = nil
        showEditProvider = false
    }

    // MARK: - Sampling

    @Published var sampling: SamplingPreset = .default

    func setSampling(_ preset: SamplingPreset) {
        sampling = preset
        recomputePlan()
    }

    // MARK: - Runtime installation

    @Published var runtimeInstallerPlan: LlamaRuntimeInstaller.Plan?
    @Published var isInstallingRuntime = false
    @Published var showBuildScript = false

    func refreshInstallerPlan() async {
        let paths = sandbox.paths
        let hostRuntime = llamaRuntime
        // `plan` runs `otool` once per library the binary loads — a subprocess
        // per dependency. Called from `onAppear`, those spawns ran on the main
        // actor and held it for as long as they took.
        runtimeInstallerPlan = await Task.detached(priority: .utility) {
            LlamaRuntimeInstaller.plan(paths: paths, hostRuntime: hostRuntime)
        }.value
    }

    /// Adopt the host runtime into the sandbox, so the app stops depending on
    /// a Homebrew install it does not own.
    func installRuntime() {
        guard case .adoptHostBinary(let source)? = runtimeInstallerPlan?.method else {
            modelStatus = "Nothing to adopt. Build from source instead — see the plan below."
            return
        }
        isInstallingRuntime = true
        modelStatus = "Copying the runtime and rewriting its dependencies…"

        let paths = sandbox.paths
        Task.detached(priority: .userInitiated) {
            do {
                let installed = try LlamaRuntimeInstaller.adopt(from: source, into: paths)
                await MainActor.run { self.isInstallingRuntime = false }
                // Awaited outside `MainActor.run`, whose closure cannot suspend,
                // and sequentially: the plan reads the runtime this refresh finds.
                await self.refreshRuntime()
                await self.refreshInstallerPlan()
                await MainActor.run {
                    self.modelStatus = "Runtime installed at \(installed.path)."
                }
            } catch {
                await MainActor.run {
                    self.isInstallingRuntime = false
                    self.modelStatus = "\(error)"
                }
            }
        }
    }

    /// The shell script that builds llama.cpp inside the sandbox.
    var runtimeBuildScript: String {
        LlamaRuntimeInstaller.buildScript(paths: sandbox.paths)
    }
}
