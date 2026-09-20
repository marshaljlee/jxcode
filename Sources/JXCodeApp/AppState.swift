import AppKit
import Foundation
import JXCodeCore
import SwiftUI

/// Live health of the local model server.
///
/// `isServing` only records that a server was *started* — it is a flag set once
/// and never revisited, so on its own it answers "is the model still loaded?"
/// with a stale yes forever, including after the process has died. This is the
/// polled answer, and the reason the UI can say anything truthful about a
/// process it does not own.
enum ServerHealth: Equatable {
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

@MainActor
final class AppState: ObservableObject {

    let sandbox: Sandbox
    let registry: AgentRegistry

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
    @Published var servedModelID: String?
    @Published var servedPort: Int?
    /// What the running server says it loaded, as opposed to what the plan
    /// predicted. `nil` until it has been asked, or if it did not answer.
    @Published var servedProps: ServerProps?
    /// Where the server and the plan disagree. Empty is the good case.
    @Published var servedDisagreements: [String] = []

    /// Live state of the local server, refreshed by the poll below.
    @Published var serverHealth: ServerHealth = .idle
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
        let sandbox = Sandbox()
        self.sandbox = sandbox
        self.registry = AgentRegistry(paths: sandbox.paths)
        self.store = WorkspaceStore(paths: sandbox.paths)
        self.sharedStore = SharedStore(paths: sandbox.paths)

        self.providerStore = ProviderStore(paths: sandbox.paths)
        self.routerState = RouterState()
        self.router = ModelRouter(
            state: routerState,
            log: RouterLog(fileURL: sandbox.paths.logs.appendingPathComponent("router.log"))
        )
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
            if let first = try? store.create(name: "scratch") {
                workspaces = store.workspaces
                selectedWorkspaceID = first.id
            }
        } else if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }

        refreshProviders()
        refreshDoctor()
        refreshInstalledAgents()
        refreshShared()
        // Load the token before anything can start the router, so the first
        // request is judged against the real policy rather than a default.
        loadRouterAuth()
        refreshGitStatuses()
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    // MARK: - Workspaces

    func createWorkspace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let workspace = try store.create(name: trimmed)
            workspaces = store.workspaces
            selectedWorkspaceID = workspace.id
            tabs = []
            selectedTabID = nil
            refreshGitStatuses()
        } catch {
            banner = "Could not create workspace: \(error)"
        }
    }

    func deleteWorkspace(id: UUID) {
        // Only forgets the workspace; the directory on disk is left alone.
        try? store.remove(id: id)
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

        let controller = TerminalController(agent: agent, sandbox: sandbox, workspace: workspace)
        let tab = TabItem(terminal: controller)
        tabs.append(tab)
        selectedTabID = tab.id
        controller.start()
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
    }

    // MARK: - Tools

    /// The tools the dashboard offers.
    ///
    /// Read straight from `JXCodeCore` rather than held as state: the list is a
    /// constant, and a `@Published` copy of a constant is one more thing that can
    /// disagree with itself.
    var tools: [ToolDefinition] { ToolCatalog.builtIns }

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
        controller.start()
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
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
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
        try? providerStore.remove(id: id)
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
                try? providerStore.add(updated)

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
                providerStatus = message
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
            return
        }
        let tab = TabItem.sharedCollection()
        tabs.append(tab)
        selectedTabID = tab.id
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
        case .skills:      return sharedSkills.count
        case .agents:      return registry.agents.count
        case .connectors:  return sharedConnectors.count
        case .automations: return sharedAutomations.count
        }
    }

    /// Install every connector that needs it, then write the collection into
    /// every agent that can take it.
    ///
    /// The order is not incidental. Binding a connector whose binary does not
    /// exist yet registers an MCP server that cannot start, and the agent then
    /// reports a connection failure rather than a missing install — which is a
    /// far harder thing to diagnose from the agent's side.
    func bindShared() {
        guard !isBindingShared else { return }
        isBindingShared = true
        sharedStatus = "Installing shared connectors…"

        let sandbox = self.sandbox
        let connectors = sharedConnectors
        let skills = sharedSkills
        let agents = registry.agents
        let paths = sandbox.paths

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
        try? sharedStore.removeSkill(id: id)
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
            banner = "Could not write the connector: \(error)"
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
        try? sharedStore.removeConnector(id: id)
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
        try? sharedStore.removeAutomation(id: id)
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
        typealias Probe = (LlamaRuntime?, [(path: URL, origin: LlamaRuntime.Origin, exists: Bool)])
        let probe: Probe = await Task.detached(priority: .utility) {
            let locator = LlamaRuntimeLocator(paths: paths)
            return (locator.locate(), locator.diagnostics())
        }.value
        llamaRuntime = probe.0
        runtimeDiagnostics = probe.1
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
            sampling: sampling
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
        for tab in tabs {
            tab.terminate()
        }
        tabs.removeAll()
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

    /// The tail of the running server's log, for the pane.
    var llamaLogTail: String {
        llamaServer?.logTail() ?? ""
    }

    /// Register the served model as a backend, so the router can use it.
    func registerServedModelAsProvider() {
        guard let model = selectedLocalModel, let port = servedPort else { return }
        let provider = Provider(
            name: "\(model.displayName) (local)",
            kind: .localGGUF,
            baseURL: "http://127.0.0.1:\(port)",
            models: [model.model.filename],
            // Stored so Bind knows the window even when it is pressed from the
            // Providers pane, where no local model is selected.
            contextLength: servedServerContext ?? modelPlan?.contextLength
        )
        do {
            try providerStore.add(provider)
            refreshProviders()
            modelStatus = "Registered \(provider.name). Select it in Model routing to use it."
        } catch {
            modelStatus = "Could not register the model: \(error)"
        }
    }

    /// Take the selected local model the whole way to the agents.
    ///
    /// Getting a GGUF in front of an agent used to be six steps across two
    /// panes — serve it, register it as a backend, open Model routing, select
    /// it, start the router, bind the agents — and not one of them said whether
    /// it had worked. The result was a user with a model loaded and a router
    /// running whose agents were still quietly talking to Anthropic. This walks
    /// the chain and reports each hop.
    func connectSelectedModelToAgents() async {
        guard let model = selectedLocalModel else {
            modelStatus = "Select a model first."
            return
        }

        // Hop 1 — it has to actually be loaded before anything can use it.
        if serverHealth != .healthy {
            await startServingSelectedModel()
        }
        guard serverHealth == .healthy, let port = servedPort else {
            // startServingSelectedModel has already put the reason here.
            return
        }

        // Hop 2 — the router only knows about backends, so the server has to be
        // one. Reuse the entry for this port if there is one; adding another
        // would leave a duplicate in the list on every run.
        let base = "http://127.0.0.1:\(port)"
        let existing = providerStore.providers.first { $0.normalizedBaseURL == base }
        let provider = Provider(
            id: existing?.id ?? UUID(),
            name: "\(model.displayName) (local)",
            kind: .localGGUF,
            baseURL: base,
            models: [model.model.filename],
            contextLength: servedServerContext ?? modelPlan?.contextLength
        )
        do {
            try providerStore.add(provider)
            refreshProviders()
        } catch {
            modelStatus = "Could not register the model as a backend: \(error)"
            return
        }

        // Hop 3 — point the router at it.
        selectedProviderID = provider.id
        selectModel(model.model.filename)

        // Hop 4 — agents must not be aimed at a port nothing is listening on.
        if !routerRunning {
            await startRouterAndWait()
        }
        guard routerRunning else { return }

        // Hop 5 — rewrite each agent's config.
        bindAgents()

        let count = boundAgentCount
        modelStatus = count == 0
            ? "\(model.displayName) is serving on \(base), but no agent config was written — check Model routing."
            : "\(model.displayName) is serving on \(base) and \(count) agent(s) route through \(router.baseURL)."
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
