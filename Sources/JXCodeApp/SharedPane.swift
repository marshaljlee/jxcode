import JXCodeCore
import SwiftUI

// MARK: - Sections

/// The four things the shared collection is made of.
///
/// Agents are in this list even though `SharedStore` does not own them. The
/// question the pane answers is "what do all the agents share", and the agents
/// are part of that answer — they are installed once into the sandbox and every
/// workspace uses the same binary. They are read straight from `AgentRegistry`
/// rather than mirrored into a fourth array, so there stays exactly one list of
/// agents in the app.
enum SharedSection: String, CaseIterable, Identifiable {
    case systemPrompt
    case skills
    case agents
    case connectors
    case automations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemPrompt: return "System prompt"
        case .skills:       return "Skills"
        case .agents:       return "Agents"
        case .connectors:   return "Connectors"
        case .automations:  return "Automation"
        }
    }

    var icon: MXIconName {
        switch self {
        case .systemPrompt: return .edit
        case .skills:       return .checklist
        case .agents:       return .cpu
        case .connectors:   return .connector
        case .automations:  return .clock
        }
    }

    /// What the section is for, in one or two sentences.
    ///
    /// Present in the pane rather than in a help window: "connector" and
    /// "automation" are our words, not the agents', and a user who has to guess
    /// what one means will not use it.
    var blurb: String {
        switch self {
        case .systemPrompt:
            return "One standing prompt every agent carries. The file on disk is "
                + "the source of truth; binding writes it into each agent's own "
                + "instruction file."
        case .skills:
            return "Instruction packs. Written once here and bound into each "
                + "agent's own instruction file, so there is one copy to edit."
        case .agents:
            return "Installed once inside the sandbox and shared by every "
                + "workspace — not one copy per workspace."
        case .connectors:
            return "MCP servers. Registered once and written into every agent's "
                + "own config, each of which uses a different format."
        case .automations:
            return "Agents that run themselves on a schedule, unattended, and "
                + "record what happened."
        }
    }
}

// MARK: - Sidebar block

/// The `Shared` block in the sidebar: four entries, one per section.
///
/// Deliberately *outside* the workspaces `List`. That list's selection is a
/// workspace id, and these are not workspaces — tagging them into it would mean
/// inventing UUIDs for things that have none, and the detail column would then
/// have to learn to render a workspace that is not one.
struct SharedSidebarSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                SectionLabel("Shared")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 5)

            ForEach(SharedSection.allCases) { section in
                SharedSidebarRow(section: section, count: state.sharedCount(for: section))
            }
        }
        .padding(.bottom, 7)
        .background(Theme.surface)
    }
}

private struct SharedSidebarRow: View {
    @EnvironmentObject private var state: AppState
    let section: SharedSection
    let count: Int

    @State private var isHovering = false

    var body: some View {
        Button {
            state.openShared(section)
        } label: {
            HStack(spacing: 8) {
                MXIconView(
                    name: section.icon,
                    size: 12,
                    tint: isHovering ? Theme.accent : Theme.textSecondary
                )
                .frame(width: 15)

                Text(section.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Theme.surfaceElevated : Color.clear)
                    .padding(.horizontal, 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(section.blurb)
    }
}

// MARK: - The pane

/// Browse, edit and apply the app-wide collection.
///
/// This is the surface the collection was asked for: one place where a skill,
/// connector or automation is written once and every agent picks it up. The
/// apply step is explicit rather than automatic — writing into five agents'
/// config files the moment a switch is flipped would make an accidental edit
/// immediately expensive.
struct SharedPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            SharedTabStrip(selection: $state.sharedSection)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView {
                Group {
                    switch state.sharedSection {
                    case .systemPrompt: SharedSystemPromptTab()
                    case .skills:       SharedSkillsTab()
                    case .agents:       SharedAgentsTab()
                    case .connectors:   SharedConnectorsTab()
                    case .automations:  SharedAutomationsTab()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.border)
            footer
        }
        // Fills its tab. It was pinned to 860x680 while it was a sheet, where a
        // fixed size is the point — a sheet sizes to its content, a tab is given
        // the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceDeepest)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.tileTeal)
                MXIconView(name: .layers, size: 17, tint: Theme.ink(on: Theme.tileTeal))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("Shared collection")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Available to every agent in every workspace.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text(state.sandbox.paths.display(state.sandbox.paths.shared))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.sandbox.paths.shared.path)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 8) {
                    Button {
                        state.bindShared()
                    } label: {
                        Label {
                            Text(state.isBindingShared ? "Applying…" : "Apply to all agents")
                        } icon: {
                            MXIconView(name: .arrowRight, size: 11, tint: Theme.accentOn)
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isBindingShared)

                    Button("Unbind") { state.revertShared() }
                        .font(.system(size: 11))
                        .disabled(state.isBindingShared)
                        .help("Remove every binding the collection wrote. "
                            + "The collection's contents are left alone.")

                    Button("Done") { state.closeSharedTab() }
                        .font(.system(size: 11))
                        .help("Close the Shared tab")
                }

                if state.isBindingShared {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(height: 8)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var footer: some View {
        if let status = state.sharedStatus {
            VStack(alignment: .leading, spacing: 5) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !state.sharedReports.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(state.sharedReports.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 108)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
        }
    }
}

// MARK: - Section switcher

/// The four-section switcher.
///
/// Hand-rolled rather than a segmented `Picker`, for two reasons. The stock
/// control writes back to its own selection binding as it lays out — the pane
/// was observed rendering skills, then connectors, then automations inside a
/// single run, and settling on whichever segment laid out last, so the tab the
/// user saw had nothing to do with the one they asked for. And every other
/// piece of chrome in this app is drawn from `Theme`, which made a stock
/// control the one element that did not match.
private struct SharedTabStrip: View {
    @Binding var selection: SharedSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SharedSection.allCases) { section in
                SharedTabButton(section: section, isSelected: section == selection) {
                    selection = section
                }
            }
        }
        .padding(4)
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

private struct SharedTabButton: View {
    let section: SharedSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MXIconView(
                    name: section.icon,
                    size: 11,
                    tint: isSelected ? Theme.accentOn : Theme.textSecondary
                )
                Text(section.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accentOn : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    // `accentFill` with `accentOn`, not `accent` with white: the
                    // selected pill is the reference's amber button, and white on
                    // amber fails contrast in both modes.
                    .fill(isSelected
                          ? Theme.accentFill
                          : (isHovering ? Theme.surfaceElevated : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Shared row chrome

/// One entry in any of the four lists.
///
/// The sections differ in their detail text and their controls but not in their
/// shape — a tinted tile, a name, a line of detail, and whatever the row can do.
/// Sharing the shape is what stops the pane reading as four unrelated screens.
private struct SharedEntryRow<Trailing: View>: View {
    let icon: MXIconName
    let tint: Color
    let title: String
    let detail: String
    var isEnabled: Bool = true
    /// Shown in place of `detail`, in warning colour: a validation error, or why
    /// the last run failed. Separate from `detail` because it is the one line
    /// the user actually has to act on.
    var problem: String?
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            IconTile(icon: icon, color: isEnabled ? tint : Theme.textTertiary, size: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                if let problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        // Unlimited, matching the `problem` branch above.
                        //
                        // This was `lineLimit(2)`, which is a line for the
                        // summary and a line for one finding — enough while
                        // findings were short, and not enough the moment one
                        // grew: the advisory that says a description is the
                        // skill's own name renders at about 145 characters and
                        // came out as "…say when to use it instead;…" with the
                        // remedy, which is the half the user has to act on,
                        // cut off. A row is allowed to be taller than its
                        // neighbours; a finding nobody can finish reading is
                        // the same as no finding.
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            trailing
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Theme.surfaceElevated : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }
}

/// The heading above each list, with the add control.
private struct SharedTabHeader: View {
    let section: SharedSection
    let count: Int
    /// `nil` for a read-only section — the Agents tab has nothing to add,
    /// because agents are added from the launcher, not from here.
    let addLabel: String?
    @Binding var isAdding: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surfaceElevated))
                }
                Text(section.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if let addLabel {
                Button {
                    isAdding.toggle()
                } label: {
                    Label {
                        Text(isAdding ? "Cancel" : addLabel)
                    } icon: {
                        MXIconView(name: isAdding ? .close : .add, size: 11)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}

private struct SharedEmptyState: View {
    let icon: MXIconName
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MXIconView(name: icon, size: 15, tint: Theme.textTertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Theme.border)
        )
    }
}

/// A labelled field, so the four forms line up without four hand-tuned layouts.
private struct SharedField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            content
        }
    }
}

private struct SharedFormShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceDeepest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.borderStrong, lineWidth: 1)
        )
    }
}

// MARK: - System prompt tab

/// Edit the shared system prompt and push it to every agent.
///
/// The editor edits the **file on disk**, which is the source of truth — the
/// pane is a view onto `shared/system-prompt.md`, not a database record with a
/// file behind it. Save writes the file; "Apply to all agents" (the pane
/// header's own button) runs the binder.
private struct SharedSystemPromptTab: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = ""
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("System prompt")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if state.systemPrompt.enabled {
                            Badge(text: "on", color: Theme.success,
                                  background: Theme.success.opacity(0.14))
                        } else {
                            Badge(text: "off", color: Theme.textSecondary)
                        }
                    }
                    Text("Carried by every agent in every workspace. ")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 16)

                Toggle("Enabled", isOn: Binding(
                    get: { state.systemPrompt.enabled },
                    set: { state.setSystemPromptEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            // The source of truth itself. Monospaced because prompts are
            // written *at* machines as often as at people, and line-exact
            // edits are common.
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button {
                    state.saveSystemPrompt(body: draft)
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.primaryCompact)
                .disabled(draft == state.systemPrompt.body)
                .help("Write shared/system-prompt.md — the source of truth")

                Button("Revert") { draft = state.systemPrompt.body }
                    .font(.system(size: 11))
                    .disabled(draft == state.systemPrompt.body)

                Button {
                    state.saveSystemPrompt(body: draft)
                    state.bindSystemPrompt()
                } label: {
                    HStack(spacing: 5) {
                        MXIconView(name: .arrowRight, size: 10, tint: Theme.accent)
                        Text("Save & bind to all agents")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Write the file and push it into every agent's instruction file")

                Spacer(minLength: 0)

                if let status = state.systemPromptStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .onAppear {
            if !isLoaded {
                draft = state.systemPrompt.body
                isLoaded = true
            }
        }
    }
}

// MARK: - Skills

private struct SharedSkillsTab: View {
    @EnvironmentObject private var state: AppState

    @State private var isAdding = false
    @State private var name = ""
    @State private var summary = ""
    /// Not `body` — that name is the `View` protocol's own requirement, and a
    /// stored property of the same name is a redeclaration, not a shadow.
    @State private var skillBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SharedTabHeader(
                section: .skills,
                count: state.sharedSkills.count,
                addLabel: "New skill",
                isAdding: $isAdding
            )

            if isAdding { form }

            if state.sharedSkills.isEmpty, !isAdding {
                SharedEmptyState(
                    icon: .checklist,
                    text: "No shared skills yet. A skill is a Markdown file the "
                        + "agents read — a release checklist, a house style, a "
                        + "definition of done."
                )
            }

            ForEach(state.sharedSkills) { skill in
                SharedEntryRow(
                    icon: .checklist,
                    tint: Theme.tilePurple,
                    title: skill.name,
                    detail: detail(for: skill),
                    isEnabled: skill.enabled,
                    problem: blockingProblem(for: skill)
                ) {
                    Toggle("", isOn: Binding(
                        get: { skill.enabled },
                        set: { state.setSkillEnabled(id: skill.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(skill.enabled
                          ? "Linked into every agent that discovers skills, and listed "
                            + "in the instruction files"
                          : "Switched off — not bound anywhere")

                    Button {
                        state.removeSkill(id: skill.id)
                    } label: {
                        MXIconView(name: .trash, size: 11, tint: Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this skill")
                }
            }
        }
    }

    /// The line the user has to act on, if there is one.
    ///
    /// A blocking finding means an agent will reject the file, so it replaces
    /// the summary rather than sitting under it — this is the one case where
    /// the row stops being a description and becomes a warning. It is also why
    /// findings are computed here rather than only at bind time: a problem that
    /// first appears when the collection is applied arrives long after the
    /// author stopped thinking about the skill.
    private func blockingProblem(for skill: Skill) -> String? {
        skill.findings.first { $0.severity == .blocking }?.rendered
    }

    /// The summary, plus anything advisory worth saying.
    ///
    /// Advisory findings load fine, so they do not displace the summary — but
    /// they are the difference between a skill that gets used and one that
    /// never does, which is worth a line.
    private func detail(for skill: Skill) -> String {
        var lines = [skill.summary.isEmpty
            ? SkillStore.skillFile(id: skill.id, paths: state.sandbox.paths).path
            : skill.summary]
        lines += skill.findings.filter { $0.severity == .advisory }.map(\.rendered)
        return lines.joined(separator: "\n")
    }

    private var form: some View {
        SharedFormShell {
            SharedField(label: "NAME") {
                TextField("Release checklist", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            // The id is what the file is named, and the specification requires
            // the `name:` inside it to match — so it is worth showing before
            // the skill exists. The reserved-name warning belongs here rather
            // than at Add time because the fix is to change the name, and that
            // is much easier before pressing the button than after.
            if let hint = idHint {
                Text(hint.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hint.isBlocking ? Theme.warning : Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SharedField(label: "WHAT IT IS FOR — ONE LINE, SHOWN TO THE AGENT") {
                TextField("Steps to run before tagging a release", text: $summary)
                    .textFieldStyle(.roundedBorder)
                    .help(SkillAuthoring.tooltip)

                // The rule, live, under the field it is about.
                //
                // Shown while the description is being typed rather than on
                // Add, because the fix is to change the text and that is much
                // cheaper before the button than after. The placeholder above
                // is the worked example; this is the reason it is that
                // sentence.
                //
                // A hint and never a gate — the Add button stays enabled. A
                // form that refuses a loadable skill is enforcing a style, and
                // the specification does not have one.
                if let hint = SkillAuthoring.hint(name: name, description: summary) {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SharedField(label: "BODY") {
                TextEditor(text: $skillBody)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 130)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            HStack {
                Text("Markdown. Written to SKILL.md; the agents read that file directly.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Add skill", action: commit)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit() {
        state.addSkill(name: name, summary: summary, body: skillBody)
        name = ""
        summary = ""
        skillBody = ""
        isAdding = false
    }

    /// What the name will become on disk, and whether that is a name the agents
    /// keep for themselves.
    private var idHint: (text: String, isBlocking: Bool)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let id = Identifier.slug(trimmed, fallback: "skill")
        if SkillSpec.isReserved(id) {
            return ("\(id) is a name the agents reserve — a skill at it would "
                + "never load", true)
        }
        return ("id: \(id)", false)
    }
}

// MARK: - Agents

private struct SharedAgentsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SharedTabHeader(
                section: .agents,
                count: state.registry.agents.count,
                addLabel: nil,
                isAdding: .constant(false)
            )

            ForEach(state.registry.agents, id: \.id) { agent in
                SharedEntryRow(
                    icon: AgentPresentation.icon(for: agent.id),
                    tint: Theme.tile(for: agent.id),
                    title: agent.name,
                    detail: detail(for: agent),
                    isEnabled: state.isInstalled(agentID: agent.id)
                ) {
                    if state.isInstalled(agentID: agent.id) {
                        Badge(
                            text: "ready",
                            color: Theme.success,
                            background: Theme.success.opacity(0.14)
                        )
                    } else {
                        Badge(text: "not installed")
                    }
                }
            }

            Text("Add or remove agents from the launcher, not from here — the "
                + "collection binds into whatever agents exist.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 2)
        }
    }

    /// Says what the collection can actually do with this agent, rather than
    /// leaving the user to infer it from a switch that never appears.
    private func detail(for agent: AgentDefinition) -> String {
        let bindable = SkillBinder.instructionFile(for: agent, paths: state.sandbox.paths) != nil
        let base = agent.installCommand == nil ? agent.command : "installed inside the sandbox"
        return bindable
            ? "\(base) · takes shared skills and connectors"
            : "\(base) · takes no shared instructions"
    }
}

// MARK: - Connectors

private struct SharedConnectorsTab: View {
    @EnvironmentObject private var state: AppState

    @State private var isAdding = false
    @State private var name = ""
    @State private var transport: ConnectorTransport = .stdio
    @State private var command = ""
    @State private var arguments = ""
    @State private var url = ""
    @State private var assignments = ""
    @State private var installCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SharedTabHeader(
                section: .connectors,
                count: state.sharedConnectors.count,
                addLabel: "New connector",
                isAdding: $isAdding
            )

            if isAdding { form }

            if state.sharedConnectors.isEmpty, !isAdding {
                SharedEmptyState(
                    icon: .connector,
                    text: "No connectors yet. A connector is an MCP server — a "
                        + "filesystem, a database, a browser. Register it once and "
                        + "every agent can call it."
                )
            }

            ForEach(state.sharedConnectors) { connector in
                SharedEntryRow(
                    icon: .connector,
                    tint: connector.transport == .stdio ? Theme.tileTeal : Theme.tileOrange,
                    title: connector.name,
                    detail: detail(for: connector),
                    isEnabled: connector.enabled,
                    // A credential the definition holds outright outranks an
                    // incomplete one: both stop the connector being bound, and
                    // only one of them is also a leak. `SharedEntryRow` shows
                    // one line, so it shows the one that has to be acted on.
                    problem: connector.validationError
                        ?? connector.inlinedCredentials.first?.rendered
                ) {
                    Toggle("", isOn: Binding(
                        get: { connector.enabled },
                        set: { state.setConnectorEnabled(id: connector.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Button {
                        state.removeConnector(id: connector.id)
                    } label: {
                        MXIconView(name: .trash, size: 11, tint: Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this connector")
                }
            }
        }
    }

    /// The row's second line: what the connector is, and what it needs.
    ///
    /// The names and never the values. A row is the most-copied surface in the
    /// app — screenshots, bug reports, pasted into a chat — and a token that
    /// appears in one has leaked in the way this track exists to prevent. The
    /// variable's name is also the more useful half: it is the thing the user
    /// has to go and set.
    private func detail(for connector: Connector) -> String {
        let what = connector.transport == .stdio
            ? connector.argv.joined(separator: " ")
            : connector.url
        let referenced = connector.referencedVariables
        guard !referenced.isEmpty else { return what }
        let subject = referenced.count == 1
            ? "names \(referenced[0])"
            : "names \(referenced.joined(separator: ", "))"
        return "\(what)\n\(subject)"
    }

    private var form: some View {
        SharedFormShell {
            HStack(alignment: .top, spacing: 10) {
                SharedField(label: "NAME") {
                    TextField("filesystem", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                SharedField(label: "TRANSPORT") {
                    Picker("", selection: $transport) {
                        ForEach(ConnectorTransport.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Spacer(minLength: 0)
            }

            if transport == .stdio {
                SharedField(label: "COMMAND") {
                    TextField("npx", text: $command)
                        .textFieldStyle(.roundedBorder)
                }
                SharedField(label: "ARGUMENTS — SPACE SEPARATED") {
                    TextField("-y @modelcontextprotocol/server-filesystem ~/Projects", text: $arguments)
                        .textFieldStyle(.roundedBorder)
                }
                SharedField(label: "ENVIRONMENT — K=V, COMMA SEPARATED") {
                    TextField("API_KEY=${API_KEY}", text: $assignments)
                        .textFieldStyle(.roundedBorder)
                }
                SharedField(label: "SHARED INSTALL — RUN ONCE, INTO shared/bin") {
                    TextField("npm install -g @modelcontextprotocol/server-filesystem",
                              text: $installCommand)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                SharedField(label: "URL") {
                    TextField("https://example.com/mcp", text: $url)
                        .textFieldStyle(.roundedBorder)
                }
                SharedField(label: "HEADERS — K=V, COMMA SEPARATED") {
                    TextField("Authorization=Bearer ${GITHUB_TOKEN}", text: $assignments)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let hint = credentialHint {
                Text(hint.text)
                    .font(.system(size: 10))
                    .foregroundStyle(hint.isProblem ? Theme.warning : Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("An install command lands in the shared prefix, which is on "
                    + "every agent's PATH — so the next agent gets it for free.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Register", action: commit)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || credentialHint?.isProblem == true)
            }
        }
    }

    /// The line under the credential field, and the only one that can block.
    ///
    /// Two states, and the difference matters. A value that *names* its secret
    /// is the thing to encourage, so the name is read back — and only the name:
    /// neither this nor the CLI ever prints the value, which is the same rule
    /// the binder follows. A value that *holds* one disables Register rather
    /// than failing after the press, because the store refuses it either way and
    /// a button that always errors is worse than one that is off with the
    /// reason on screen.
    private var credentialHint: (text: String, isProblem: Bool)? {
        let pairs = Assignments.parse(assignments)
        let findings = transport == .stdio
            ? CredentialScan.findings(environment: pairs, headers: [:])
            : CredentialScan.findings(environment: [:], headers: pairs)
        if let finding = findings.first { return (finding.rendered, true) }

        var referenced: [String] = []
        for value in pairs.values {
            for name in CredentialReference.names(in: value) where !referenced.contains(name) {
                referenced.append(name)
            }
        }
        guard !referenced.isEmpty else { return nil }

        let subject = referenced.count == 1
            ? "names \(referenced[0])"
            : "names \(referenced.joined(separator: ", "))"
        // `NAME`, not one of the names that happens to be in this field. The
        // example on `CredentialSyntax` is `${GITHUB_TOKEN}`, which was printed
        // here for a connector whose only variable was `API_KEY` — the same
        // reason-contradicts-its-value defect the CLI had, found the same way,
        // by reading the sentence next to the thing it was describing.
        return ("\(subject) — stored as \(CredentialSyntax.shell.render("NAME")) and rewritten "
            + "into each agent's own spelling when you bind, so the value never reaches "
            + "a config file. Set it in the sandbox environment, not here.", false)
    }

    private func commit() {
        let pairs = Assignments.parse(assignments)
        let connector = Connector(
            id: Identifier.slug(name, fallback: "connector"),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: transport,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty },
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: transport == .http ? pairs : [:],
            environment: transport == .stdio ? pairs : [:],
            installCommand: installCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : installCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        state.addConnector(connector)
        name = ""
        command = ""
        arguments = ""
        url = ""
        assignments = ""
        installCommand = ""
        isAdding = false
    }
}

// MARK: - Automations

private struct SharedAutomationsTab: View {
    @EnvironmentObject private var state: AppState

    @State private var isAdding = false
    @State private var name = ""
    @State private var agentID = ""
    @State private var prompt = ""
    @State private var workspaceID: UUID?
    @State private var cadence: AutomationSchedule.Cadence = .daily
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = 2
    @State private var intervalMinutes = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SharedTabHeader(
                section: .automations,
                count: state.sharedAutomations.count,
                addLabel: "New automation",
                isAdding: $isAdding
            )

            if isAdding { form }

            if state.sharedAutomations.isEmpty, !isAdding {
                SharedEmptyState(
                    icon: .clock,
                    text: "No automations yet. An automation is an agent, a "
                        + "prompt and a schedule — a nightly triage, a weekly "
                        + "dependency check."
                )
            }

            if !state.sharedAutomations.isEmpty {
                HStack {
                    Button {
                        state.runDueAutomations()
                    } label: {
                        Label {
                            Text("Run what is due")
                        } icon: {
                            MXIconView(name: .play, size: 11)
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.link)

                    Spacer()

                    Text(dueSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            ForEach(state.sharedAutomations) { automation in
                SharedEntryRow(
                    icon: AgentPresentation.icon(for: automation.agentID),
                    tint: Theme.tile(for: automation.agentID),
                    title: automation.name,
                    detail: "\(automation.schedule.summary)  →  \(automation.agentID)",
                    isEnabled: automation.enabled,
                    // A failed run is the one thing on this row that needs an
                    // answer, so it takes the detail line rather than sitting
                    // beside it.
                    problem: failureText(automation)
                ) {
                    Button {
                        state.runAutomation(id: automation.id)
                    } label: {
                        MXIconView(name: .play, size: 11, tint: Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Run this now, schedule or not")

                    Toggle("", isOn: Binding(
                        get: { automation.enabled },
                        set: { state.setAutomationEnabled(id: automation.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Button {
                        state.removeAutomation(id: automation.id)
                    } label: {
                        MXIconView(name: .trash, size: 11, tint: Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this automation")
                }
            }
        }
        .onAppear {
            // Default the agent picker to something real rather than an empty
            // menu, and only to an agent that can actually run unattended.
            if agentID.isEmpty {
                agentID = automatableAgents.first?.id ?? state.registry.agents.first?.id ?? ""
            }
        }
    }

    /// Only the agents JXCode knows how to drive non-interactively.
    ///
    /// Offering the rest would be offering a schedule that fails every time it
    /// fires, which is worse than not offering it.
    private var automatableAgents: [AgentDefinition] {
        state.registry.agents.filter {
            AutomationRunner.nonInteractiveInvocation(agent: $0, prompt: "x") != nil
        }
    }

    private var dueSummary: String {
        let due = AutomationRunner.due(automations: state.sharedAutomations).count
        if due == 0 { return "nothing is due right now" }
        return "\(due) due now"
    }

    private func failureText(_ automation: Automation) -> String? {
        guard let result = automation.lastResult else { return nil }
        return result.hasPrefix("failed:") ? "last run — \(result)" : nil
    }

    private var form: some View {
        SharedFormShell {
            HStack(alignment: .top, spacing: 10) {
                SharedField(label: "NAME") {
                    TextField("Nightly triage", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                SharedField(label: "AGENT") {
                    Picker("", selection: $agentID) {
                        ForEach(automatableAgents, id: \.id) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                SharedField(label: "WORKSPACE") {
                    Picker("", selection: $workspaceID) {
                        Text("Sandbox home").tag(UUID?.none)
                        ForEach(state.workspaces) { workspace in
                            Text(workspace.name).tag(UUID?.some(workspace.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                Spacer(minLength: 0)
            }

            SharedField(label: "PROMPT — PASSED TO THE AGENT AS ITS FIRST ARGUMENT") {
                TextField("Summarise what changed on main since yesterday", text: $prompt)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 10) {
                SharedField(label: "CADENCE") {
                    Picker("", selection: $cadence) {
                        ForEach(AutomationSchedule.Cadence.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                switch cadence {
                case .daily:
                    SharedField(label: "HOUR") { numberField($hour, range: 0...23) }
                    SharedField(label: "MINUTE") { numberField($minute, range: 0...59) }
                case .weekly:
                    SharedField(label: "WEEKDAY") {
                        Picker("", selection: $weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(weekdayName(day)).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    SharedField(label: "HOUR") { numberField($hour, range: 0...23) }
                    SharedField(label: "MINUTE") { numberField($minute, range: 0...59) }
                case .interval:
                    SharedField(label: "EVERY N MINUTES") {
                        TextField("", value: $intervalMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack {
                Text(schedulePreview)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Register", action: commit)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || prompt.trimmingCharacters(in: .whitespaces).isEmpty
                              || agentID.isEmpty)
            }
        }
    }

    private func numberField(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 62)
            .onChange(of: value.wrappedValue) { _, new in
                value.wrappedValue = min(max(new, range.lowerBound), range.upperBound)
            }
    }

    private var schedulePreview: String {
        let schedule = AutomationSchedule(
            cadence: cadence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            intervalMinutes: intervalMinutes
        )
        return "Runs \(schedule.summary.lowercased())."
    }

    private func weekdayName(_ value: Int) -> String {
        let names = ["", "Sunday", "Monday", "Tuesday", "Wednesday",
                     "Thursday", "Friday", "Saturday"]
        return names[min(max(value, 1), 7)]
    }

    private func commit() {
        let schedule = AutomationSchedule(
            cadence: cadence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            intervalMinutes: intervalMinutes
        )

        let automation = Automation(
            id: uniqueAutomationID(Identifier.slug(name, fallback: "automation")),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            agentID: agentID,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceID: workspaceID,
            schedule: schedule
        )

        state.addAutomation(automation)
        name = ""
        prompt = ""
        workspaceID = nil
        isAdding = false
    }

    /// `writeAutomation` overwrites by id, so a second automation with the same
    /// slug would silently replace the first.
    private func uniqueAutomationID(_ base: String) -> String {
        let taken = Set(state.sharedAutomations.map(\.id))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}
