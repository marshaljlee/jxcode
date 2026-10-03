import JXCodeCore
import SwiftUI

/// Register a backend, pick a model, and route every agent at it.
///
/// This is pillar 02's user-facing surface. The intent is that the whole flow —
/// add a URL, see the models it serves, choose one, start the router, and have
/// every installed agent use it — happens here without editing a config file.
struct ProvidersPane: View {

    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    routerSection
                    routeProofSection
                    if state.lastRouterError != nil { upstreamErrorBanner }
                    if !state.lastTranslationNotes.isEmpty { translationNotesBanner }
                    authSection
                    backendSection
                    modelSection
                    agentSection
                    if !state.routerLogLines.isEmpty { logSection }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $state.showEditProvider) {
            EditProviderSheet(state: state)
        }
    }

    // MARK: - Access control

    private var authSection: some View {
        SectionCard(
            title: "Access control",
            subtitle: "The router holds your API keys, so anything on this machine that can reach its port can spend them."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Require a token", isOn: Binding(
                    get: { state.routerAuth.isEnabled },
                    set: { state.setRouterAuthEnabled($0) }
                ))
                .font(.system(size: 12))

                if state.routerAuth.isEnabled {
                    HStack(spacing: 8) {
                        Text(state.routerAuth.token ?? "no token")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Regenerate") { state.regenerateRouterToken() }
                            .controlSize(.small)
                        Spacer()
                    }
                    Text("Agents already bound to the router are rewritten with the new token. "
                        + "Both x-api-key and Authorization: Bearer are accepted, because "
                        + "different agents send different ones.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Off. Any process on this machine that can reach port "
                        + "\(String(state.routerPort)) can use your keys — the same trust "
                        + "boundary as a local Ollama or LM Studio.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Router

    /// A rejection from the backend, said plainly.
    ///
    /// Without this the failure is invisible: the agent gets an error it
    /// renders as nothing, and "my provider has no credit" looks identical to
    /// "routing is broken".
    private var upstreamErrorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MXIconView(name: .warning, size: 14, tint: Theme.warning)
                Text("The backend refused the last request")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            }
            Text(state.lastRouterError ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Routing itself is working — this is the provider answering. "
                 + "Check its credits, its key, or pick a different backend or model.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.warning.opacity(0.35), lineWidth: 1)
        )
    }

    /// What the translator had to leave behind on the last request.
    ///
    /// Deliberately not the error banner, because nothing failed: the request
    /// was answered. But a translation that drops a block produces an answer
    /// that looks fine and behaves wrong — the agent stops seeing tool output,
    /// a thinking model's trace vanishes between turns, a server tool the
    /// client asked for is never reported — and these notes are the only place
    /// that is said out loud. The card disappears when the list is empty,
    /// because "the last request carried everything" is not worth a card.
    private var translationNotesBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MXIconView(name: .routing, size: 14, tint: Theme.textSecondary)
                Text("The last translation could not carry everything")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            ForEach(state.lastTranslationNotes, id: \.self) { note in
                Text("· \(note)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("The request still succeeded — this is what the backend was not told. "
                 + "Pick a backend that speaks the Anthropic wire (a llama-server, or "
                 + "Anthropic itself) if any of it matters for what you are doing.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.textSecondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.textSecondary.opacity(0.25), lineWidth: 1)
        )
    }

    /// One press, not two.
    ///
    /// This card used to end in `Start`, and the *next* card ended in `Route
    /// agents through the router` — two presses that only worked in that order,
    /// in two different places, with nothing saying they were a pair. Pressing
    /// Start alone left a router listening and every agent still on Anthropic,
    /// which is a state that looks finished. `Activate` runs the whole chain and
    /// reports each hop.
    private var routerSection: some View {
        SectionCard(
            title: "Local router",
            subtitle: "Every agent talks to this. It translates between the Anthropic and OpenAI APIs and forwards to the backend you choose."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(state.routerRunning ? Theme.success : Theme.textTertiary)
                        .frame(width: 9, height: 9)

                    Text(state.routerRunning
                         ? "Listening on \(state.router.baseURL)"
                         : "Stopped")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.routerRunning ? Theme.textPrimary : Theme.textSecondary)

                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("Port")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("5255", value: $state.routerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(state.routerRunning)
                    Text("Loopback only — the router holds your API keys, so it never binds to the network.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await state.activateSelectedBackend() }
                    } label: {
                        Label {
                            Text(state.isActivating ? "Activating…" : "Activate routing")
                        } icon: {
                            MXIconName.bolt.view(size: 12)
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(state.selectedProvider == nil || state.isActivating)

                    if state.isActivating {
                        ProgressView().controlSize(.small)
                    }

                    if state.routerRunning {
                        Button("Stop") { state.stopRouter() }
                            .controlSize(.small)
                    }

                    Spacer()
                }

                Text("Loads a local model if that is what you picked, registers the backend, "
                    + "starts the router, points every agent at it, and then sends one real "
                    + "request through the whole chain to prove it works.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let report = state.activationReport {
                    ActivationReportCard(report: report)
                }
            }
        }
    }

    /// Prove the route, not the reply.
    ///
    /// The card exists because the failure it catches is invisible everywhere
    /// else. `/health` is answered from the router's own configuration, and a
    /// proxied request and a translated one both come back as a perfectly good
    /// Anthropic message — so "it works" is equally true of a router doing the
    /// wrong thing. The only witness is the backend, so this stands one up: a
    /// listener on loopback that answers by path, drives the same corpus
    /// through every route, and reports what each one was actually asked for.
    ///
    /// Nothing is registered and no key is spent, which is why this can sit
    /// next to Activate without the user having to think about what it costs.
    private var routeProofSection: some View {
        SectionCard(
            title: "Route proof",
            subtitle: "Send real requests through the router at a recording backend, and check what each route actually sent it."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { await state.proveRoutes() }
                    } label: {
                        Label {
                            Text(state.isProvingRoute ? "Proving…" : "Prove the route")
                        } icon: {
                            MXIconName.checklist.view(size: 12)
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(state.isProvingRoute)

                    if state.isProvingRoute {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()
                }

                Text("Your configured backend is not used. The recording backend is on loopback "
                    + "and is gone when the proof ends, so this spends nothing and proves "
                    + "something about the router rather than about your provider.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let report = state.routeProofReport {
                    RouteProofCard(report: report)
                }
            }
        }
    }

    // MARK: - Backends

    private var backendSection: some View {
        SectionCard(
            title: "Backends",
            subtitle: "Any OpenAI-compatible server, a native Anthropic endpoint, or Ollama. Models are fetched from the server, never hard-coded."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if state.providers.isEmpty {
                    Text("No backends yet. Add one below.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(state.providers) { provider in
                        providerRow(provider)
                    }
                }

                Divider()

                addForm
            }
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let isSelected = state.selectedProvider?.id == provider.id

        return HStack(alignment: .top, spacing: 10) {
            Button {
                state.selectProvider(id: provider.id)
            } label: {
                MXIconView(
                    name: isSelected ? .check : .circle,
                    size: 14,
                    tint: isSelected ? Theme.accent : Theme.textTertiary
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    KindBadge(kind: provider.kind)
                    if provider.apiKey == nil, provider.kind != .ollama, provider.kind != .localGGUF {
                        Text("no key")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Text(provider.normalizedBaseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text(provider.models.isEmpty
                     ? "no models fetched"
                     : "\(provider.models.count) model(s)")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if state.isProbing, isSelected {
                ProgressView().controlSize(.small)
            }

            Button {
                state.selectProvider(id: provider.id)
                state.probeSelectedProvider()
            } label: {
                MXIconView(name: .refresh, size: 13, tint: Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Fetch the model list")

            Button {
                state.beginEditingProvider(provider)
            } label: {
                MXIconView(name: .edit, size: 13, tint: Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Edit this backend, including its API key")

            Button {
                state.removeProvider(id: provider.id)
            } label: {
                MXIconView(name: .trash, size: 13, tint: Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Forget this backend")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.selectProvider(id: provider.id) }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a backend").font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                TextField("Name", text: $state.newProviderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Picker("", selection: $state.newProviderKind) {
                    Text("OpenAI-compatible").tag(ProviderKind.openAICompatible)
                    Text("Anthropic").tag(ProviderKind.anthropic)
                    Text("Ollama").tag(ProviderKind.ollama)
                }
                .labelsHidden()
                .frame(width: 180)
            }

            TextField("Base URL, e.g. http://127.0.0.1:8080/v1", text: $state.newProviderBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            HStack(spacing: 8) {
                SecureField("API key (leave blank for a local server)", text: $state.newProviderKey)
                    .textFieldStyle(.roundedBorder)

                Button("Add") { state.addProvider() }
                    .disabled(state.newProviderName.isEmpty || state.newProviderBaseURL.isEmpty)
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        SectionCard(
            title: "Model",
            subtitle: "Agents ask for their own model names — Claude Code sends `claude-sonnet-4-5`. The router rewrites whatever they ask for to the model selected here."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let provider = state.selectedProvider, !provider.models.isEmpty {
                    Picker("", selection: Binding(
                        get: { state.selectedModel ?? provider.models[0] },
                        set: { state.selectModel($0) }
                    )) {
                        ForEach(provider.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420, alignment: .leading)

                    if let model = state.selectedModel, !Provider.looksToolCapable(model) {
                        Label {
                            Text("This model may not support tool calling, "
                                + "which agent workflows depend on.")
                        } icon: {
                            MXIconName.warning.view(size: 12)
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    }
                } else {
                    Text("Fetch a backend's models to choose one.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let status = state.providerStatus {
                    Text(status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Agents

    private var agentSection: some View {
        SectionCard(
            title: "Agents",
            subtitle: "Written by Activate, from the backend and model selected above. Only the sandbox copy is touched — your host `~/.claude` is left alone."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // Re-binding, not binding. The first write happens in
                    // `Activate`; this exists because the per-agent models below
                    // are edited *after* that, and a config that still names the
                    // old model is the one thing that looks finished and is not.
                    Button("Apply per-agent models") { state.bindAgents() }
                        .disabled(
                            !state.routerRunning
                                || (state.agentModelOverrides.isEmpty
                                    && state.agentWireOverrides.isEmpty)
                        )

                    Button("Undo") { state.unbindAgents() }
                        .disabled(state.bindReports.isEmpty)

                    if !state.routerRunning {
                        Text("Start the router with Activate first.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Spacer()
                }

                // Per-agent models. One model for every agent is the wrong
                // default for a workspace: the agent doing the thinking wants
                // the strongest model, while a background helper may be better
                // served by something local and free.
                if let fallback = state.selectedModel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Per-agent models")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Blank uses \(fallback).")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        ForEach(state.registry.agents, id: \.id) { agent in
                            HStack(spacing: 8) {
                                Text(agent.name)
                                    .font(.system(size: 11))
                                    .frame(width: 110, alignment: .leading)
                                TextField(fallback, text: Binding(
                                    get: { state.agentModelOverrides[agent.id] ?? "" },
                                    set: { state.setModelOverride(agentID: agent.id, model: $0) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))

                                // A wire picker appears only where a wire
                                // exists. Codex's `config.toml` is the one
                                // config file that carries a `wire_api`, so
                                // offering the control on every other row would
                                // be offering something that cannot do anything.
                                //
                                // And only the values Codex can be *given* are
                                // listed. `messages` has no `wire_api` spelling,
                                // so it is absent rather than present and always
                                // refused.
                                if agent.routerBinding == .codexConfig {
                                    Picker("", selection: Binding(
                                        get: {
                                            state.agentWireOverrides[agent.id]
                                                ?? AgentWire.codexDefault
                                        },
                                        set: {
                                            state.setWireOverride(agentID: agent.id, wire: $0)
                                        }
                                    )) {
                                        ForEach(
                                            AgentWire.allCases.filter { $0.codexWireAPI != nil },
                                            id: \.self
                                        ) { wire in
                                            // `chat` is marked, not hidden. A
                                            // user pinned to an older Codex may
                                            // need it — it is the documented
                                            // escape hatch when a backend's
                                            // Responses streaming is broken —
                                            // but nobody should pick it without
                                            // knowing a current Codex refuses to
                                            // start on it.
                                            Text(
                                                wire.isUsableByCurrentCodex
                                                    ? wire.rawValue
                                                    : "\(wire.rawValue) (deprecated)"
                                            )
                                            .tag(wire)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 160)
                                }
                            }
                        }

                        Text(
                            "The wire is which protocol an agent speaks to the "
                            + "router. Codex removed `chat/completions` support in "
                            + "early February 2026, so `responses` is the only value "
                            + "a current Codex accepts — `chat` is kept for an older "
                            + "one, and `jxcode bind` will say so when you use it."
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }

                if !state.bindReports.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.bindReports, id: \.agentID) { report in
                            HStack(alignment: .top, spacing: 6) {
                                Text(report.action.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(color(for: report.action))
                                    .frame(width: 96, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(report.agentName).font(.system(size: 11))
                                    if let path = report.path {
                                        Text(path.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    ForEach(report.notes, id: \.self) { note in
                                        Text("· \(note)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func color(for action: AgentConfigWriter.Report.Action) -> Color {
        switch action {
        case .created:         return Theme.success
        case .merged:          return Theme.accent
        case .unchanged:       return Theme.textTertiary
        // Not a failure of ours to fix, but not silent either: the file is the
        // user's and we declined to touch it, so it earns a colour that reads as
        // "look at this" rather than as "nothing happened".
        case .refused:         return Theme.warning
        case .environmentOnly: return Theme.textTertiary
        case .notApplicable:   return Theme.textTertiary
        }
    }

    // MARK: - Log

    private var logSection: some View {
        SectionCard(
            title: "Recent requests",
            subtitle: "Every request the router handled. Useful when an agent reports something unexpected."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Refresh") { state.refreshRouterLog() }
                        .controlSize(.small)
                    Spacer()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.routerLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 160)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceElevated)
                )
            }
        }
    }
}

// MARK: - Supporting views

/// A titled card. Extracted so the pane above stays readable — nesting these
/// inline pushes SwiftUI's result builder past what it can infer.
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

/// The outcome of one press of Activate.
///
/// A list of hops rather than a sentence, because the failure this replaces was
/// never "it did not work" — it was "it did not work and nothing said which of
/// the five things was missing". Each step that is not standing carries the
/// specific move that fixes it.
struct ActivationReportCard: View {
    let report: ActivationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                MXIconView(
                    name: report.isWorking ? .check : .warning,
                    size: 14,
                    tint: report.isWorking ? Theme.success : Theme.danger
                )
                Text(report.isWorking ? "Routing is up" : "Routing did not come up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(report.isWorking ? Theme.success : Theme.danger)
                Spacer(minLength: 0)
                if let url = report.routerURL {
                    Text(url)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(report.headline)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(report.steps) { step in
                    row(step)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(report.isWorking ? Theme.success.opacity(0.08) : Theme.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    report.isWorking ? Theme.success.opacity(0.30) : Theme.danger.opacity(0.30),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func row(_ step: ActivationStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MXIconView(name: icon(step.status), size: 11, tint: tint(step.status))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(step.status == .skipped ? Theme.textTertiary : Theme.textPrimary)

                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let remedy = step.remedy, !remedy.isEmpty {
                    Text(remedy)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func icon(_ status: ActivationStep.Status) -> MXIconName {
        switch status {
        case .pass:    return .check
        case .warn:    return .warning
        case .fail:    return .close
        case .skipped: return .circle
        }
    }

    private func tint(_ status: ActivationStep.Status) -> Color {
        switch status {
        case .pass:    return Theme.success
        case .warn:    return Theme.warning
        case .fail:    return Theme.danger
        case .skipped: return Theme.textTertiary
        }
    }
}

/// The outcome of one press of Prove the route.
///
/// One block per route rather than a single verdict. "The router works" is
/// precisely the claim this replaces — three routes are exercised and they can
/// disagree, so a green tick over all three would be the same silent wrong
/// answer the proof exists to catch. Each block shows the path the backend was
/// asked for, because that is the observation, and then only the checks that
/// failed; the passing ones are the command's job to enumerate.
struct RouteProofCard: View {
    let report: RouteProofReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MXIconView(
                    name: report.isPassing ? .check : .warning,
                    size: 14,
                    tint: report.isPassing ? Theme.success : Theme.danger
                )
                Text(report.isPassing
                     ? "Every route sent what it promises"
                     : "A route is not doing what it says")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(report.isPassing ? Theme.success : Theme.danger)
                Spacer(minLength: 0)
                Text("\(report.checks.count - report.failures)/\(report.checks.count) checks")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(report.routes) { route in
                block(route)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(report.isPassing ? Theme.success.opacity(0.08) : Theme.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    report.isPassing ? Theme.success.opacity(0.30) : Theme.danger.opacity(0.30),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func block(_ route: RouteProofRoute) -> some View {
        let failures = route.checks.filter { $0.status == .fail }

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                MXIconView(
                    name: route.isPassing ? .check : .close,
                    size: 10,
                    tint: route.isPassing ? Theme.success : Theme.danger
                )
                Text(route.kind.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Text(asked(route))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }

            if failures.isEmpty {
                Text("\(route.checks.count) checks passed")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(failures) { check in
                    Text("· \(check.subject): \(check.title)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(check.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 2)
    }

    /// The distinct paths the backend was asked for.
    private func asked(_ route: RouteProofRoute) -> String {
        var distinct: [String] = []
        for path in route.backendPaths where !distinct.contains(path) {
            distinct.append(path)
        }
        return distinct.isEmpty ? "—" : distinct.joined(separator: " ")
    }
}

/// The API shape a backend speaks, as a small coloured tag.
struct KindBadge: View {
    let kind: ProviderKind

    private static func tint(for kind: ProviderKind) -> Color {
        switch kind {
        case .openAICompatible: return Theme.accent
        case .anthropic:        return Theme.tilePurple
        case .ollama:           return Theme.tileTeal
        case .localGGUF:        return Theme.tileOrange
        }
    }

    var body: some View {
        let tint = Self.tint(for: kind)
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.18))
            )
            .foregroundStyle(tint)
    }

    private var label: String {
        switch kind {
        case .openAICompatible: return "openai"
        case .anthropic:        return "anthropic"
        case .ollama:           return "ollama"
        case .localGGUF:        return "gguf"
        }
    }
}

/// The pane, framed as a sheet.
///
/// Routing is global rather than per workspace, so it does not belong in the
/// workspace tab bar — a tab would disappear every time the user switched
/// workspace, taking the running router's controls with it.
struct ProvidersSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model routing")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Serve every agent from one backend, with translation as needed.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Done") { state.showProviders = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.surfaceDeepest)

            Divider().overlay(Theme.border)

            ProvidersPane(state: state)
                .background(Theme.surfaceDeepest)
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 560, idealHeight: 660)
        .background(Theme.surfaceDeepest)
        .onAppear { state.refreshProviders() }
    }
}

// MARK: - Editing a backend

/// Edit a backend that already exists.
///
/// Adding one used to be one-way: a typo in a key or a base URL meant deleting
/// the entry and retyping everything, including re-fetching its model list.
struct EditProviderSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit backend")
                    .font(.system(size: 15, weight: .medium))
                Text("Changing the base URL keeps the fetched model list until you refresh it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let draft = state.providerDraft {
                field("Name", text: Binding(
                    get: { draft.name },
                    set: { state.providerDraft?.name = $0 }
                ))

                field("Base URL", text: Binding(
                    get: { draft.baseURL },
                    set: { state.providerDraft?.baseURL = $0 }
                ))

                HStack(spacing: 10) {
                    Text("API key")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    SecureField("sk-…", text: Binding(
                        get: { draft.apiKey ?? "" },
                        set: { state.providerDraft?.apiKey = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }

                HStack(spacing: 10) {
                    Text("Kind")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { draft.kind },
                        set: { state.providerDraft?.kind = $0 }
                    )) {
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.providerDraft = nil
                    state.showEditProvider = false
                }
                Button("Save", action: state.commitProviderDraft)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
