import JXCodeCore
import SwiftUI

/// The local model library: scan for GGUF files, see which have a vision
/// projector, see exactly how llama-server would be configured, and run one.
///
/// This is pillar 03's user-facing surface. The design intent is that the
/// computed plan is *visible and explained* rather than applied invisibly — the
/// optimiser makes real trade-offs (context length against cache precision,
/// layers against memory), and a tool that makes those choices without showing
/// its reasoning is one nobody can trust or correct.
struct ModelsPane: View {

    @ObservedObject var state: AppState

    @State private var newAliasName = ""
    @State private var newAliasPath = ""
    @State private var newAliasIdle = ""
    @State private var idleSeconds = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pipelineSection
                runtimeSection
                lifecycleSection
                if !state.servingPolicyText.isEmpty {
                    servingPolicySection
                }
                librarySection
                if let model = state.selectedLocalModel {
                    modelSection(model)
                }
                if let plan = state.modelPlan {
                    planSection(plan)
                }
                if !state.llamaLogTail.isEmpty {
                    logSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            idleSeconds = String(Int(state.activeProfileIdleTimeout))
            await state.refreshLifecycle()
            // On a timer rather than on a button, because the thing most likely
            // to change this pane is the idle sweep unloading a model with
            // nobody touching anything. A list that only updated when the user
            // asked would keep showing a model as loaded after it had gone.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await state.refreshLifecycle()
            }
        }
    }

    // MARK: - Where the model actually reaches

    /// The three hops between a file on disk and an agent using it.
    ///
    /// This answers "did it load, and is anything actually using it". Each hop
    /// can independently be false — the model can be loaded with the router
    /// stopped, or the router can be running with no agent pointed at it — and
    /// before this every one of those looked exactly like working.
    ///
    /// One button does all three. The chain used to be four presses across two
    /// panes — serve it, register it, open Model routing, start the router, bind
    /// the agents — and every one of them could be missed while the UI still
    /// looked right. `Activate` runs them in order, stops at the first thing
    /// that is not standing, and says what to do about it.
    private var pipelineSection: some View {
        SectionCard(
            title: "Reaching the agents",
            subtitle: "One press: load the model, register it, start the router and point every agent at it."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                PipelineHop(
                    icon: .cpu,
                    title: "llama-server",
                    detail: serverDetail,
                    state: serverHopState
                )
                PipelineConnector(active: serverHopState == .on)
                PipelineHop(
                    icon: .routing,
                    title: "Router",
                    detail: routerDetail,
                    state: state.routerRunning ? .on : .off
                )
                PipelineConnector(active: state.routerRunning)
                PipelineHop(
                    icon: .people,
                    title: "Agents",
                    detail: agentsDetail,
                    state: state.boundAgentCount > 0 ? .on : .off
                )

                // The log is the only record of why a server died, and it is
                // gone once the process is reaped — so it is captured at the
                // moment of death rather than read later.
                if let death = state.serverDeathLog, !death.isEmpty {
                    Text(death)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.danger.opacity(0.10))
                        )
                        .padding(.top, 10)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await state.activateSelectedLocalModel() }
                    } label: {
                        Label {
                            Text(state.isActivating ? "Activating…" : "Activate")
                        } icon: {
                            MXIconName.bolt.view(size: 12)
                        }
                    }
                    .disabled(state.selectedLocalModel == nil || state.isActivating)

                    if state.isActivating {
                        ProgressView().controlSize(.small)
                    }

                    if state.isServing {
                        Button {
                            Task { await state.stopServing() }
                        } label: {
                            Label {
                                Text("Stop")
                            } icon: {
                                MXIconName.stop.view(size: 12)
                            }
                        }
                    }

                    Button {
                        Task { await state.pollServerHealth() }
                    } label: {
                        MXIconView(name: .refresh, size: 13)
                    }
                    .help("Check the server now")

                    Spacer()
                }
                .padding(.top, 12)

                if let report = state.activationReport {
                    ActivationReportCard(report: report)
                        .padding(.top, 12)
                }
            }
        }
    }

    private var serverHopState: HopState {
        switch state.serverHealth {
        case .healthy:               return .on
        case .unreachable, .exited:  return .problem
        case .idle, .loading:        return .off
        }
    }

    private var serverDetail: String {
        guard state.isServing, let port = state.servedPort else { return "not loaded" }
        // "checked Ns ago" rather than a bare dot: a dot implies a live
        // connection, and this is a poll.
        let age = state.secondsSinceHealthCheck.map { " · checked \($0)s ago" } ?? ""
        return ":\(port) · \(state.serverHealth.label)\(age)"
    }

    private var routerDetail: String {
        guard state.routerRunning else { return "stopped" }
        return "\(state.router.baseURL) · \(state.selectedProvider?.name ?? "no backend")"
    }

    private var agentsDetail: String {
        let bound = state.bindReports.filter(\.isRouted)
        guard !bound.isEmpty else { return "none pointed at the router" }
        return bound.map(\.agentName).joined(separator: ", ")
    }


    // MARK: - Model lifecycle (track 1.3)

    /// The alias table, what is loaded, and the four log streams.
    ///
    /// This is the half of 1.3 the pane was missing. `Reaching the agents`
    /// above wires one *named file* to the agents; this is the layer that makes
    /// the name stable instead — an agent's config holds `coder`, and which file
    /// that means is decided here and nowhere an agent reads.
    ///
    /// The one rule it follows throughout is the sandbox configuration pane's:
    /// show the *effective* value, not the form. An alias with no timeout of its
    /// own is not "no timeout", it is the profile's number, and the difference
    /// decides whether a 16 GB model survives a coffee break.
    @ViewBuilder
    private var lifecycleSection: some View {
        SectionCard(
            title: "Model lifecycle",
            subtitle: "Agents ask for a name. Which file that name means is decided here, and the model loads only when something asks for it."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                profileControls
                Divider()
                aliasTable
                Divider()
                loadedModels
                if !state.foreignServers.isEmpty {
                    Divider()
                    foreignServerList
                }
                Divider()
                logStreamControls

                if let status = state.lifecycleStatus, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Why jxcode never lets llama-server serve a directory of models itself.
    ///
    /// Track 1.4 decided this and the decision had nowhere to live. A section
    /// rather than a paragraph in the README because two of its three facts are
    /// about *this machine* — whether the installed binary has router mode at
    /// all, and whether anything is in it right now — and neither is knowable
    /// from a document.
    ///
    /// The text is the core's, not the view's: `jxcode local policy` prints the
    /// same string, so the window and the terminal cannot come to different
    /// conclusions about the same decision.
    @ViewBuilder
    private var servingPolicySection: some View {
        SectionCard(
            title: "One model per server",
            subtitle: "Why jxcode keeps its own router instead of letting llama-server serve a directory of models."
        ) {
            Text(state.servingPolicyText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var profileControls: some View {
        HStack(spacing: 10) {
            Text("Profile")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Picker("", selection: Binding(
                get: { state.activeProfileName },
                set: { state.selectProfile($0) }
            )) {
                ForEach(state.knownProfileNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            Text("idle timeout")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            TextField("900", text: $idleSeconds)
                .frame(width: 66)
                .onSubmit { applyIdleTimeout() }
            Text("s")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button("Apply") { applyIdleTimeout() }
                .controlSize(.small)

            Spacer()

            Button {
                Task { await state.refreshLifecycle() }
            } label: {
                MXIconView(name: .refresh, size: 13)
            }
            .buttonStyle(.borderless)
            .help("Ask every loaded server how it is")

            // The timer is a convenience, not the mechanism: a laptop that
            // sleeps fires no timers, and a pane that says "idle — due to
            // unload" should not make the user wait for one.
            Button {
                Task { await state.sweepNow() }
            } label: {
                Text("Sweep now").font(.caption)
            }
            .help("Unload whatever is past its idle timeout, without waiting for the timer")
        }

        Text("An alias with no timeout of its own unloads after "
            + "\(RunningModel.duration(state.activeProfileIdleTimeout)) idle. "
            + "0 keeps a model loaded until it is stopped by hand.")
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var aliasTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aliases")
                .font(.system(size: 12, weight: .semibold))

            if state.boundAliases.isEmpty {
                Text("None bound. An alias is what an agent's config holds, so the file "
                    + "behind it can move without rewriting every agent.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.boundAliases) { alias in
                    aliasRow(alias)
                }
            }

            HStack(spacing: 6) {
                TextField("name", text: $newAliasName)
                    .frame(width: 96)
                TextField("path to a .gguf", text: $newAliasPath)
                TextField("idle s", text: $newAliasIdle)
                    .frame(width: 58)
                Button("Bind") { bindAlias() }
                    .controlSize(.small)
                    .disabled(newAliasName.isEmpty || newAliasPath.isEmpty)
            }
            .font(.system(size: 12))
        }
    }

    private func aliasRow(_ alias: ModelAlias) -> some View {
        let idle = state.effectiveIdleTimeout(alias)
        let loaded = state.runningModels.contains {
            $0.alias.caseInsensitiveCompare(alias.name) == .orderedSame
        }
        let onDisk = FileManager.default.fileExists(
            atPath: (alias.modelPath as NSString).expandingTildeInPath
        )

        return HStack(alignment: .top, spacing: 10) {
            MXIconView(
                name: loaded ? .play : .circle,
                size: 12,
                tint: loaded ? Theme.success : Theme.textTertiary
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(alias.name)
                        .font(.system(size: 12, weight: .medium))
                    if !onDisk {
                        // Reported rather than refused. An alias to a model on an
                        // unmounted external drive is a normal state, and the
                        // only place it is visible before a request fails
                        // minutes later is here.
                        Text("missing")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Text(alias.modelPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ModelLifecycleReport.idleLine(
                    idle,
                    origin: ModelLifecycleReport.idleOrigin(alias)
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    if loaded { await state.stopAlias(alias.name) }
                    else { await state.startAlias(alias.name) }
                }
            } label: {
                Text(loaded ? "Unload" : "Load").font(.caption)
            }
            .controlSize(.small)

            Button {
                state.unbindAlias(alias.name)
            } label: {
                MXIconView(name: .close, size: 11, tint: Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Unbind — agents asking for this name stop resolving")
        }
    }

    @ViewBuilder
    private var loadedModels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loaded now")
                .font(.system(size: 12, weight: .semibold))

            if state.runningModels.isEmpty {
                Text("Nothing loads until a request needs it — the first agent to ask for "
                    + "an alias starts its model, and the idle timeout stops it again.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.runningModels, id: \.alias) { model in
                    loadedRow(model)
                }
            }
        }
    }

    private func loadedRow(_ model: RunningModel) -> some View {
        let health = state.lifecycleHealth[model.alias]
        let report = state.lifecycleMetrics[model.alias]

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.alias)
                    .font(.system(size: 12, weight: .medium))
                Text(model.filename)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    Task { await state.stopAlias(model.alias) }
                } label: {
                    Text("Unload").font(.caption)
                }
                .controlSize(.small)
            }

            Text(model.summary(now: Date()))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)

            if let health {
                Label {
                    Text(health.description)
                } icon: {
                    (health.isHealthy ? MXIconName.check : MXIconName.warning).view(size: 10)
                }
                .font(.system(size: 10))
                .foregroundStyle(health.isHealthy ? Theme.success : Theme.warning)
            }

            if let report {
                if let metrics = report.metrics {
                    Text(metricsLine(metrics))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                } else if let problem = report.problem {
                    // The server's own sentence where it has one — most often
                    // "Start it with --metrics", which is a fix, not a failure.
                    Text(problem)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceElevated))
    }

    /// The counters this build was observed to report, and `not reported` for
    /// the rest.
    ///
    /// "0 requests" and "this build does not count requests" are different
    /// facts, and only one of them is a reason to go and look at the server.
    private func metricsLine(_ metrics: ServerMetrics) -> String {
        func counter(_ label: String, _ value: Double?) -> String {
            "\(label) \(value.map { String(Int($0)) } ?? "not reported")"
        }
        return [
            counter("prompt", metrics.promptTokens),
            counter("generated", metrics.predictedTokens),
            counter("gen tok/s", metrics.predictedTokensPerSecond),
            metrics.isBusy ? "busy" : "idle",
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private var foreignServerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running elsewhere")
                .font(.system(size: 12, weight: .semibold))
            Text("llama-server processes this app did not start. A supervisor's registry "
                + "lives in the process that made it, so these can only be found by looking.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(state.foreignServers, id: \.pid) { server in
                HStack(alignment: .top, spacing: 8) {
                    Text(server.alias ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(server.alias == nil ? Theme.textTertiary : Theme.textPrimary)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.modelPath ?? "no model on the command line")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("pid \(server.pid)"
                            + (server.baseURL.map { "  ·  \($0)" }
                                ?? "  ·  no --port on the command line"))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var logStreamControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Logs")
                    .font(.system(size: 12, weight: .semibold))

                Picker("", selection: Binding(
                    get: { state.logStream },
                    set: { state.logStream = $0; state.refreshLogStream() }
                )) {
                    ForEach(ModelLogStream.allCases) { stream in
                        Text(stream.title).tag(stream)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                if state.logStream.isPerModel {
                    Picker("", selection: Binding(
                        get: { state.logStreamAlias ?? state.boundAliases.first?.name ?? "" },
                        set: { state.logStreamAlias = $0; state.refreshLogStream() }
                    )) {
                        ForEach(state.boundAliases) { alias in
                            Text(alias.name).tag(alias.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                Spacer()

                Button {
                    state.refreshLogStream()
                } label: {
                    MXIconView(name: .refresh, size: 12)
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 12))

            Text(state.logStream.purpose)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            ScrollView {
                Text(state.logStreamTail.isEmpty ? "(nothing written yet)" : state.logStreamTail)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceElevated))
        }
    }

    private func bindAlias() {
        let idle = newAliasIdle.isEmpty ? nil : TimeInterval(newAliasIdle)
        state.bindAlias(name: newAliasName, path: newAliasPath, idleTimeout: idle)
        // Cleared only when it actually took, so a rejected path stays on screen
        // beside the reason it was rejected instead of vanishing.
        if state.boundAliases.contains(where: {
            $0.name.caseInsensitiveCompare(newAliasName) == .orderedSame
        }) {
            newAliasName = ""
            newAliasPath = ""
            newAliasIdle = ""
        }
    }

    private func applyIdleTimeout() {
        guard let seconds = TimeInterval(idleSeconds), seconds >= 0 else { return }
        state.setProfileIdleTimeout(seconds)
    }

    // MARK: - Runtime

    private var runtimeSection: some View {
        SectionCard(
            title: "Runtime",
            subtitle: "llama-server is what actually loads a GGUF file. The app looks inside its own sandbox first, then on the host."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let runtime = state.llamaRuntime {
                    HStack(spacing: 8) {
                        OriginBadge(isSandbox: runtime.isIsolated)
                        Text(runtime.binary.path)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Text(runtime.isolationNote)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label {
                        Text("No llama-server found")
                    } icon: {
                        MXIconName.warning.view(size: 13)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    Text("A local GGUF model cannot be served without it. These are the places the app looked:")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(state.runtimeDiagnostics, id: \.path.path) { entry in
                            HStack(spacing: 6) {
                                MXIconView(
                                    name: entry.exists ? .check : .circle,
                                    size: 10,
                                    tint: entry.exists
                                        ? Theme.success
                                        : Theme.textTertiary
                                )
                                Text(entry.origin == .sandbox ? "sandbox" : "host")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 54, alignment: .leading)
                                Text(entry.path.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceElevated))
                }

                Divider()

                installerControls
            }
        }
    }

    // MARK: - Installing the runtime

    /// Give the app its own copy of llama-server.
    ///
    /// Borrowing the host's is a real limitation, not a cosmetic one: the whole
    /// thesis is that installing something inside JXCode keeps it inside JXCode,
    /// and a model runner that only works because Homebrew happens to be
    /// installed contradicts that. Adopting the binary means copying it *and*
    /// every library it loads, rewriting the paths between them, and re-signing
    /// — a plain copy is a 42 KB launcher that cannot start.
    @ViewBuilder
    private var installerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime ownership")
                .font(.system(size: 12, weight: .semibold))

            if let plan = state.runtimeInstallerPlan {
                Text(plan.explanation)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(plan.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 6) {
                        MXIconView(name: .warning, size: 10, tint: Theme.warning)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    switch plan.method {
                    case .adoptHostBinary:
                        Button {
                            state.installRuntime()
                        } label: {
                            Label {
                                Text("Copy into the sandbox")
                            } icon: {
                                MXIconName.download.view(size: 12)
                            }
                        }
                        .disabled(state.isInstallingRuntime)

                    case .buildFromSource:
                        Button {
                            state.showBuildScript = true
                        } label: {
                            Label {
                                Text("Show build script")
                            } icon: {
                                MXIconName.build.view(size: 12)
                            }
                        }
                    }

                    if state.isInstallingRuntime {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                Button("Check what is available") { Task { await state.refreshInstallerPlan() } }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        SectionCard(
            title: "Library",
            subtitle: "GGUF files found on disk, with each vision projector matched to the model it belongs to."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        state.scanModels()
                    } label: {
                        Label {
                            Text(state.modelScan == nil ? "Scan for models" : "Rescan")
                        } icon: {
                            MXIconName.refresh.view(size: 12)
                        }
                    }
                    .disabled(state.isScanningModels)

                    // Without this there is no way in: the roots below are
                    // discovered at startup, and a GGUF anywhere else — an
                    // external drive, a download folder — was unreachable
                    // however many times you rescanned.
                    Button {
                        chooseModelFolder()
                    } label: {
                        Label {
                            Text("Add folder…")
                        } icon: {
                            MXIconName.folderAdd.view(size: 12)
                        }
                    }

                    if state.isScanningModels {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    if let scan = state.modelScan {
                        Text("\(scan.totalModels) models · \(scan.visionModels) with vision")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if state.modelRoots.isEmpty {
                    Text("No folders yet — add the one holding your .gguf files.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if !state.modelRoots.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.modelRoots, id: \.self) { root in
                            HStack(spacing: 6) {
                                MXIconView(
                                    name: .folder,
                                    size: 11,
                                    tint: Theme.textSecondary
                                )
                                Text(root)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    state.removeModelRoot(root)
                                } label: {
                                    MXIconView(
                                        name: .close,
                                        size: 11,
                                        tint: Theme.textSecondary
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let scan = state.modelScan {
                    if scan.models.isEmpty {
                        Text("No GGUF models found in the configured directories.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(scan.models) { model in
                                ModelRow(
                                    model: model,
                                    isSelected: model.id == state.selectedModelID,
                                    isServing: model.id == state.servedModelID,
                                    select: { state.selectLocalModel(id: model.id) }
                                )
                                if model.id != scan.models.last?.id { Divider() }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                    }

                    if !scan.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(scan.warnings, id: \.self) { warning in
                                HStack(alignment: .top, spacing: 6) {
                                    MXIconView(name: .warning, size: 10, tint: Theme.warning)
                                    Text(warning)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else if !state.isScanningModels {
                    Text("Scan a directory to see the models on this machine. Nothing is modified — this only reads each file's header.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Pick the folder holding the model files, then scan it immediately.
    ///
    /// A directory, not a file: the scanner reads every GGUF under the root and
    /// pairs each one with its mmproj, so handing it a single file would lose
    /// the projector match — which is the part users get wrong by hand.
    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose the folder containing your .gguf files"
        // Open where the models already are, so adding a second folder does not
        // mean navigating from the root of the disk again.
        let start = state.modelRoots.first.map { ($0 as NSString).expandingTildeInPath }
            ?? NSHomeDirectory()
        panel.directoryURL = URL(fileURLWithPath: start)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.addModelRoot(url.path)
    }

    // MARK: - Selected model

    private func modelSection(_ model: LocalModel) -> some View {
        SectionCard(title: model.displayName, subtitle: model.model.summary) {
            VStack(alignment: .leading, spacing: 10) {
                KeyValueRow(label: "Model", value: model.model.filename)
                if let projector = model.projector {
                    KeyValueRow(
                        label: "Vision projector",
                        value: projector.filename,
                        note: model.pairing.map { "matched by \($0.rawValue)" }
                    )
                }
                KeyValueRow(label: "Size", value: OptimizationPlan.formatBytes(UInt64(model.totalSizeBytes)))
                if let info = model.model.info {
                    KeyValueRow(label: "Architecture", value: info.architecture ?? "—")
                    if let vocabulary = info.vocabularySize {
                        KeyValueRow(
                            label: "Vocabulary",
                            value: "\(vocabulary) tokens",
                            note: "also how a bare `llama` architecture is told apart from Llama 3"
                        )
                    }
                    if let experts = info.expertCount, experts > 1 {
                        KeyValueRow(
                            label: "Experts",
                            value: "\(experts)",
                            note: "mixture-of-experts — the compute buffer is sized smaller"
                        )
                    }
                    if let perToken = info.kvBytesPerToken(bytesPerElement: 2) {
                        KeyValueRow(
                            label: "KV per token",
                            value: OptimizationPlan.formatBytes(UInt64(perToken)),
                            note: "at f16 — this is what limits the context"
                        )
                    }
                }
                if let problem = model.projectorProblem {
                    Label {
                        Text(problem)
                    } icon: {
                        MXIconName.warning.view(size: 12)
                    }
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    // MARK: - Plan

    private func planSection(_ plan: OptimizationPlan) -> some View {
        SectionCard(
            title: "How this model will run",
            subtitle: "Derived from the model's own metadata and the memory this machine can spare. Every choice below is explained."
        ) {
            VStack(alignment: .leading, spacing: 14) {

                HStack(spacing: 16) {
                    Picker("Memory", selection: Binding(
                        get: { state.memoryPolicy },
                        set: { state.setMemoryPolicy($0) }
                    )) {
                        ForEach(MemoryPolicy.allCases, id: \.self) { policy in
                            Text(policy.rawValue.capitalized).tag(policy)
                        }
                    }
                    .frame(width: 190)

                    Picker("Cache", selection: Binding(
                        get: { state.cachePolicy },
                        set: { state.setCachePolicy($0) }
                    )) {
                        ForEach(CachePolicy.allCases, id: \.self) { policy in
                            Text(policy.rawValue.capitalized).tag(policy)
                        }
                    }
                    .frame(width: 190)

                    Picker("Sampling", selection: Binding(
                        get: { state.sampling },
                        set: { state.setSampling($0) }
                    )) {
                        ForEach(SamplingPreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .frame(width: 190)
                }
                .font(.system(size: 12))

                Text("\(plan.policy.rawValue.capitalized) memory allows \(Int(plan.policy.fraction * 100))% of "
                    + "\(plan.hardware.formattedMemory); \(plan.cachePolicy.explanation). "
                    + "Sampling is \(plan.sampling.label.lowercased()) — \(plan.sampling.explanation)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !plan.templateNote.isEmpty {
                    Text(plan.templateNote)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Whether the chosen template can express a tool call. This is
                // the difference between an agent that works and one that
                // answers in prose, and nothing else in the UI says so.
                if plan.templateToolCalling == .unsupported {
                    Label {
                        Text("This model's template has no tool handling — "
                            + "agents will not be able to call tools with it.")
                    } icon: {
                        MXIconName.warning.view(size: 12)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // The headline numbers.
                HStack(spacing: 22) {
                    Statistic(label: "Context", value: "\(plan.contextLength / 1024)k")
                    Statistic(label: "Cache", value: plan.cacheTypeK.rawValue)
                    Statistic(label: "GPU layers", value: "\(plan.gpuLayers)")
                    Statistic(label: "Threads", value: "\(plan.threads)")
                }

                MemoryBar(plan: plan)

                // The arguments, each with the reason it was chosen.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Arguments")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(Array(plan.arguments.enumerated()), id: \.offset) { _, argument in
                        HStack(alignment: .top, spacing: 10) {
                            Text(argument.rendered)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 190, alignment: .leading)
                                .textSelection(.enabled)
                            Text(argument.reason)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if !plan.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 6) {
                                MXIconView(name: .warning, size: 10, tint: Theme.warning)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                servingControls(plan)

                if state.servedModelID == state.selectedModelID, state.isServing {
                    servedReport
                }
            }
        }
    }

    // MARK: - What the server actually loaded

    /// The plan above is a prediction made from the GGUF header. This is the
    /// server's own account of what it loaded, which is the only thing that can
    /// contradict it — and the difference is invisible otherwise, because a
    /// template that cannot call tools fails by producing prose rather than an
    /// error.
    @ViewBuilder
    private var servedReport: some View {
        Divider().padding(.vertical, 6)

        HStack(spacing: 8) {
            Text("Verified against the running server")
                .font(.caption.weight(.semibold))
            Spacer()
            Button {
                Task { await state.refreshServedProps() }
            } label: {
                MXIconView(name: .refresh, size: 13)
            }
            .buttonStyle(.borderless)
            .help("Ask the server again")
        }

        if let props = state.servedProps {
            if !state.servedDisagreements.isEmpty {
                ForEach(state.servedDisagreements, id: \.self) { problem in
                    Label {
                        Text(problem)
                    } icon: {
                        MXIconName.warning.view(size: 12)
                    }
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
            } else {
                Label {
                    Text("The server agrees with the plan.")
                } icon: {
                    MXIconName.check.view(size: 12)
                }
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            }

            Text(props.summary)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            if let caps = props.capabilities, !caps.supported.isEmpty {
                Text("Template supports: \(caps.supported.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let build = props.buildInfo {
                Text("llama.cpp \(build)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Text("The server did not report its configuration. It may still be starting.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }

        toolProbeReport
    }

    /// The live probe, beside the prediction it replaces.
    ///
    /// Both are shown, and that is the point rather than politeness to the old
    /// code. `servedProps` above reads `chat_template_caps` — the template
    /// saying what it can do. This is the model doing it. Where the two
    /// disagree the disagreement *is* the finding, and it is the one failure
    /// mode this app otherwise cannot see.
    @ViewBuilder
    private var toolProbeReport: some View {
        Divider().padding(.vertical, 6)

        HStack(spacing: 8) {
            Text("Tool calling, observed")
                .font(.caption.weight(.semibold))
            Spacer()
            Button {
                Task { await state.refreshToolProbe() }
            } label: {
                Text(state.isProbingTools ? "Probing…" : "Probe")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(state.isProbingTools || !state.isServing)
            .help("Send one message and one tool, and see what the model does with them")
        }

        if let prediction = state.modelPlan?.templateToolCalling {
            Text("Predicted: \(predictionLabel(prediction))")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let probe = state.servedToolProbe {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(probe.mark)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(probe.isVerified ? Theme.success : Theme.warning)
                Text(probe.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if probe.verdict == .proseInstead,
               let prose = probe.prose?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prose.isEmpty {
                // What it said instead is the whole diagnosis. A paraphrase of
                // it would be a worse version of the evidence.
                Text("It said: \"\(prose.prefix(300))\"")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(probe.detail)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if state.isServing {
            Text("Not probed yet.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        } else {
            Text("Serve a model to find out whether it actually calls tools.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func predictionLabel(_ prediction: ChatTemplateLibrary.ToolCallingSupport) -> String {
        switch prediction {
        case .supported:   return "supported — the model's own template handles tools"
        case .unsupported: return "unsupported — the template contains no tool handling"
        case .unknown:     return "unknown — nothing readable said either way"
        }
    }

    @ViewBuilder
    private func servingControls(_ plan: OptimizationPlan) -> some View {
        let isServingThis = state.servedModelID == state.selectedModelID && state.isServing

        // No "Use in routing" button here any more. It was the second half of a
        // two-step flow — register the model, then go to the other pane and
        // start the router — and it registered a backend without pointing the
        // router at it, which is a state that looks finished and is not.
        // `Activate` above does both, and this card is about the plan, not about
        // the chain.
        HStack(spacing: 10) {
            if isServingThis {
                Button {
                    Task { await state.stopServing() }
                } label: {
                    Label {
                        Text("Stop")
                    } icon: {
                        MXIconName.stop.view(size: 12)
                    }
                }

                if let port = state.servedPort {
                    Text("port \(port)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Button {
                    Task { await state.startServingSelectedModel() }
                } label: {
                    Label {
                        Text("Serve this model")
                    } icon: {
                        MXIconName.play.view(size: 12)
                    }
                }
                .disabled(state.llamaRuntime == nil || state.isServing)

                Text("Serving alone does not reach an agent — press Activate above to wire it up.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Log

    private var logSection: some View {
        SectionCard(title: "llama-server output", subtitle: "The tail of the running server's log.") {
            ScrollView {
                Text(state.llamaLogTail)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceElevated))
        }
    }
}

// MARK: - Sheet

struct ModelsSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local models")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Serve a GGUF file from this machine, with the projector, template and memory limits worked out for you.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Done") { state.showModels = false }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.surfaceDeepest)

            Divider().overlay(Theme.border)

            ModelsPane(state: state)
                .background(Theme.surfaceDeepest)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 600, idealHeight: 720)
        .background(Theme.surfaceDeepest)
        .onAppear {
            // Awaited in order, not in parallel: the installer plan reads the
            // runtime that `refreshRuntime()` is what finds.
            Task {
                await state.refreshRuntime()
                await state.refreshInstallerPlan()
                await state.refreshLifecycle()
                if state.modelScan == nil { state.scanModels() }
            }
        }
        .sheet(isPresented: $state.showBuildScript) {
            BuildScriptSheet(state: state)
        }
    }
}

// MARK: - Build script

/// The script that builds llama.cpp inside the sandbox.
///
/// Shown rather than run: it is a 30-minute compile, and starting one without
/// asking would be hostile. It is also the honest answer for a machine with no
/// existing runtime to adopt — the app cannot ship a binary it does not have.
struct BuildScriptSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build llama.cpp in the sandbox")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Takes roughly half an hour. Nothing outside the sandbox is touched.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Done") { state.showBuildScript = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                Text(state.runtimeBuildScript)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: - Components

/// Whether one hop in the pipeline is doing its job.
private enum HopState {
    case off
    case on
    case problem

    var color: Color {
        switch self {
        case .off:     return Theme.textTertiary
        case .on:      return Theme.success
        case .problem: return Theme.danger
        }
    }
}

/// One hop: icon, name, live detail, status dot.
private struct PipelineHop: View {
    let icon: MXIconName
    let title: String
    let detail: String
    let state: HopState

    var body: some View {
        HStack(spacing: 10) {
            MXIconView(
                name: icon,
                size: 12,
                tint: state == .off ? Theme.textTertiary : Theme.textPrimary
            )
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 5)
    }
}

/// The link between two hops, lit only when the hop above is actually up.
///
/// Without this the three rows read as three unrelated facts; the connector is
/// what makes it obvious that a lit router with a dark agent row means the
/// chain stops there.
private struct PipelineConnector: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(active ? Theme.success.opacity(0.45) : Theme.border)
                .frame(width: 1, height: 9)
                .padding(.leading, 22)
            Spacer(minLength: 0)
        }
    }
}

private struct ModelRow: View {
    let model: LocalModel
    let isSelected: Bool
    let isServing: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                MXIconView(
                    name: isServing ? .play : (isSelected ? .check : .circle),
                    size: 14,
                    tint: isServing
                        ? Theme.success
                        : (isSelected ? Theme.accent : Theme.textTertiary)
                )
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(model.model.summary)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if model.hasVision {
                            Label {
                                Text("vision")
                            } icon: {
                                MXIconName.eye.view(size: 10)
                            }
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.info)
                        }
                        if model.model.isSymlink {
                            Text("symlink")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Spacer()

                Text(OptimizationPlan.formatBytes(UInt64(model.totalSizeBytes)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
    }
}

private struct OriginBadge: View {
    let isSandbox: Bool

    var body: some View {
        Text(isSandbox ? "sandbox" : "host")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSandbox ? Theme.success.opacity(0.18) : Theme.warning.opacity(0.18))
            )
            .foregroundStyle(isSandbox ? Theme.success : Theme.warning)
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct Statistic: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
        }
    }
}

/// The memory breakdown, as a single proportional bar.
///
/// A table of numbers makes it easy to miss that a plan is using 97% of the
/// budget; a bar makes that obvious at a glance, which is the point.
private struct MemoryBar: View {
    let plan: OptimizationPlan

    private var total: Double { max(1, Double(plan.memoryBudgetBytes)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    segment(plan.estimatedWeightsBytes, total: geometry.size.width, color: Theme.chartWeights)
                    segment(plan.estimatedKVCacheBytes, total: geometry.size.width, color: Theme.chartKVCache)
                    segment(plan.estimatedProjectorBytes, total: geometry.size.width, color: Theme.chartProjector)
                    segment(plan.estimatedComputeBytes, total: geometry.size.width, color: Theme.chartCompute)

                    let used = Double(plan.estimatedTotalBytes) / total
                    if used < 1 {
                        Rectangle()
                            .fill(Theme.textTertiary.opacity(0.18))
                            .frame(width: geometry.size.width * (1 - used))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 16)

            HStack(spacing: 14) {
                legend("Weights", Theme.chartWeights)
                legend("KV cache", Theme.chartKVCache)
                if plan.estimatedProjectorBytes > 0 { legend("Projector", Theme.chartProjector) }
                legend("Compute", Theme.chartCompute)
                Spacer()
                Text("\(OptimizationPlan.formatBytes(plan.estimatedTotalBytes)) of "
                    + "\(OptimizationPlan.formatBytes(plan.memoryBudgetBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(plan.memoryUsedFraction > 0.9 ? Theme.warning : Theme.textSecondary)
            }
        }
    }

    private func segment(_ bytes: UInt64, total width: Double, color: Color) -> some View {
        let fraction = Double(bytes) / total
        return Rectangle()
            .fill(color.opacity(Palette.chartSegmentAlpha))
            .frame(width: max(0, width * min(fraction, 1)))
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(Palette.chartSegmentAlpha))
                .frame(width: 9, height: 9)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
        }
    }
}
