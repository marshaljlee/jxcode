import AppKit
import JXCodeCore
import SwiftUI

// MARK: - Picking the primary operator

/// Choose which agent runs the session.
///
/// This exists because the launcher could only do one thing with an agent — open
/// it — and so the choice of who was in charge was never made anywhere. It was
/// made implicitly, by whichever card you happened to click first, and it could
/// not be changed afterwards without closing the tab and reopening another.
///
/// The sheet answers three questions in one place: who is in charge, how much
/// they may delegate, and whether they may install what a job needs. Anything
/// chosen here is written to `state/primary.json`, so the CLI reads the same
/// answer this sheet shows — there is no second copy to drift.
struct PrimaryPickerSheet: View {
    @EnvironmentObject private var state: AppState

    /// Which card is highlighted. Seeded to the current primary so reopening the
    /// sheet does not silently move the highlight onto somebody else.
    @State private var selection: String?
    @State private var maxSubagents: Int = 4
    @State private var canInstallTools: Bool = true

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 10)]

    /// Installed first, because an agent that is not there cannot be made primary
    /// in any useful sense — it would open a tab that immediately fails. The
    /// rest stay on the list and say so, rather than vanishing, because "why is
    /// Crush missing" is better answered by a card that says "not installed"
    /// than by its absence.
    private var agents: [AgentDefinition] {
        state.registry.agents.sorted { lhs, rhs in
            let leftInstalled = state.isInstalled(agentID: lhs.id)
            let rightInstalled = state.isInstalled(agentID: rhs.id)
            if leftInstalled != rightInstalled { return leftInstalled }
            return lhs.name < rhs.name
        }
    }

    private var chosen: AgentDefinition? {
        guard let selection else { return nil }
        return state.registry.agent(id: selection)
    }

    /// Whether the highlighted agent can actually be made primary now.
    private var canConfirm: Bool {
        guard let chosen else { return false }
        return state.isInstalled(agentID: chosen.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(agents) { agent in
                        card(for: agent)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: 268)

            settings
            footer
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: seedFromCurrentPrimary)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pick the primary agent")
                .font(.system(size: 15, weight: .medium))
            Text("It gets the workspace, decides the plan, and may call the other agents as helpers.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func card(for agent: AgentDefinition) -> some View {
        let isInstalled = state.isInstalled(agentID: agent.id)
        let isCurrent = state.isPrimary(agentID: agent.id)
        let isSelected = selection == agent.id

        return Button {
            selection = agent.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    AgentIconTile(agentID: agent.id, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(isInstalled ? "installed" : "not installed")
                            .font(.system(size: 10))
                            .foregroundStyle(isInstalled ? Theme.success : Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                Text(AgentPresentation.tagline(for: agent))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    Badge(
                        text: "current primary",
                        color: Theme.accent,
                        background: Theme.accent.opacity(0.16)
                    )
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.glow : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInstalled)
        .opacity(isInstalled ? 1 : 0.55)
        .help(isInstalled
              ? "Make \(agent.name) the primary agent"
              : "\(agent.name) is not installed. Open its card on the dashboard to install it first.")
    }

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SUBAGENTS AT ONCE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 8) {
                        Stepper(
                            "\(maxSubagents)",
                            value: $maxSubagents,
                            in: 0...8
                        )
                        .controlSize(.small)
                        .frame(width: 108, alignment: .leading)
                    }
                    Text("Zero means it works alone.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("INSTALL TOOLS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Toggle("May install into the sandbox", isOn: $canInstallTools)
                        .controlSize(.small)
                        .toggleStyle(.switch)
                        .font(.system(size: 11))
                    Text("Free and local only. Never anything that needs a card.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if let chosen {
                summary(for: chosen)
            }
        }
    }

    /// What picking this agent actually means, in one sentence each.
    ///
    /// Written out rather than left implied, because "primary" is a word this
    /// app has never used before and the cost of picking the wrong one is a
    /// session pointed the wrong way.
    private func summary(for agent: AgentDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("IF \(agent.name.uppercased()) IS PRIMARY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            bullet("It opens automatically and receives its orders on start.")
            bullet(maxSubagents == 0
                ? "It may not open other agents."
                : "It may open up to \(maxSubagents) other agent\(maxSubagents == 1 ? "" : "s") at a time.")
            bullet(canInstallTools
                ? "It may install tools into the sandbox, free and local only."
                : "It may not install anything.")
            bullet("\(state.availableSubagents.count) other agent(s) are installed and can be called.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.primary != nil {
                Button("Remove primary") {
                    state.clearPrimary()
                    seedFromCurrentPrimary()
                }
                .controlSize(.small)
            }

            Spacer()

            Button("Cancel") {
                state.showPrimaryPicker = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Make primary") {
                guard let selection else { return }
                state.setPrimary(
                    agentID: selection,
                    maxSubagents: maxSubagents,
                    canInstallTools: canInstallTools
                )
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm)
        }
    }

    /// Adopt the stored record so the sheet opens showing the truth.
    ///
    /// The stored numbers win over the defaults: a primary chosen with "no
    /// installs" must not come back as "may install" just because the sheet was
    /// reopened.
    private func seedFromCurrentPrimary() {
        guard let record = state.primary,
              state.registry.agent(id: record.agentID) != nil else {
            // No primary yet: highlight the first agent that can actually run,
            // so the common case is one click rather than a hunt.
            selection = agents.first { state.isInstalled(agentID: $0.id) }?.id
            maxSubagents = 4
            canInstallTools = true
            return
        }
        selection = record.agentID
        maxSubagents = record.maxSubagents
        canInstallTools = record.canInstallTools
    }
}
