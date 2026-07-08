import SwiftUI
import JXCODECore

struct AgentsListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showingAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ClaudeThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Custom Agents Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("My Agents")
                            .font(.system(size: ClaudeTheme.size(10), weight: .bold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)

                        if appState.agents.isEmpty {
                            Text("No custom agents created.")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(appState.agents) { agent in
                                agentRow(for: agent)
                            }
                        }
                    }

                    // Background Runs History Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent runs")
                            .font(.system(size: ClaudeTheme.size(10), weight: .bold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)

                        if appState.agentRuns.isEmpty {
                            Text("No recent executions.")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(appState.agentRuns) { run in
                                runRow(for: run)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AgentEditSheet(agent: nil) { newAgent in
                Task {
                    await appState.addAgent(
                        name: newAgent.name,
                        icon: newAgent.icon,
                        prompt: newAgent.systemPrompt,
                        defaultTask: newAgent.defaultTask,
                        model: newAgent.model,
                        fileRead: newAgent.enableFileRead,
                        fileWrite: newAgent.enableFileWrite,
                        network: newAgent.enableNetwork,
                        hooks: newAgent.hooks
                    )
                }
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("AI Agents")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)

            Spacer()

            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                    .foregroundStyle(ClaudeTheme.accent)
            }
            .buttonStyle(.borderless)
            .help("Create new custom agent")
        }
    }

    private func agentRow(for agent: Agent) -> some View {
        let isSelected = windowState.selectedAgentId == agent.id
        
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                windowState.selectedAgentId = agent.id
            }
        } label: {
            HStack(spacing: 8) {
                Text(agent.icon)
                    .font(.system(size: ClaudeTheme.size(16)))
                    .frame(width: 24, height: 24)
                    .background(isSelected ? ClaudeTheme.accent.opacity(0.15) : ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                        .lineLimit(1)
                    
                    Text(agent.model)
                        .font(.system(size: ClaudeTheme.size(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? ClaudeTheme.surfaceSecondary : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Agent", role: .destructive) {
                Task { await appState.deleteAgent(id: agent.id) }
                if windowState.selectedAgentId == agent.id {
                    windowState.selectedAgentId = nil
                }
            }
        }
    }

    private func runRow(for run: AgentRun) -> some View {
        let isSelected = windowState.selectedAgentId == run.id
        
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                windowState.selectedAgentId = run.id
            }
        } label: {
            HStack(spacing: 8) {
                // Status icon
                Group {
                    switch run.status {
                    case "running":
                        ProgressView()
                            .controlSize(.mini)
                    case "completed":
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case "failed":
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    default:
                        Image(systemName: "clock")
                            .foregroundStyle(.gray)
                    }
                }
                .font(.system(size: ClaudeTheme.size(12)))
                .frame(width: 20, height: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.task)
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                        .lineLimit(1)
                    
                    Text("\(run.agentName) • \(formatDate(run.startedAt))")
                        .font(.system(size: ClaudeTheme.size(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? ClaudeTheme.surfaceSecondary : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Agent Edit Sheet

struct AgentEditSheet: View {
    let agent: Agent?
    let onSave: (Agent) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String
    @State private var icon: String
    @State private var systemPrompt: String
    @State private var defaultTask: String
    @State private var model: String
    @State private var fileRead: Bool
    @State private var fileWrite: Bool
    @State private var network: Bool
    
    init(agent: Agent?, onSave: @escaping (Agent) -> Void) {
        self.agent = agent
        self.onSave = onSave
        
        _name = State(initialValue: agent?.name ?? "")
        _icon = State(initialValue: agent?.icon ?? "🤖")
        _systemPrompt = State(initialValue: agent?.systemPrompt ?? "")
        _defaultTask = State(initialValue: agent?.defaultTask ?? "")
        _model = State(initialValue: agent?.model ?? "claude-3-5-sonnet-20241022")
        _fileRead = State(initialValue: agent?.enableFileRead ?? true)
        _fileWrite = State(initialValue: agent?.enableFileWrite ?? true)
        _network = State(initialValue: agent?.enableNetwork ?? false)
    }
    
    let icons = ["🤖", "🧠", "🔨", "⚡️", "🕵️", "📦", "🎨", "🔬", "📈", "⚙️"]
    let models = [
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022",
        "claude-3-opus-20240229"
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(agent == nil ? "New Agent" : "Edit Agent")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding()
            .background(ClaudeTheme.surfaceSecondary)
            
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    
                    Picker("Icon", selection: $icon) {
                        ForEach(icons, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                }
                
                Section("Behavior") {
                    TextField("System Prompt (Instructions)", text: $systemPrompt, axis: .vertical)
                        .lineLimit(4...8)
                    TextField("Default Task Query", text: $defaultTask)
                }
                
                Section("Configuration") {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    
                    Toggle("Enable File Read", isOn: $fileRead)
                    Toggle("Enable File Write", isOn: $fileWrite)
                    Toggle("Enable Network Access", isOn: $network)
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Spacer()
                Button("Save Agent") {
                    let newAgent = Agent(
                        id: agent?.id ?? UUID(),
                        name: name,
                        icon: icon,
                        systemPrompt: systemPrompt,
                        defaultTask: defaultTask.isEmpty ? nil : defaultTask,
                        model: model,
                        enableFileRead: fileRead,
                        enableFileWrite: fileWrite,
                        enableNetwork: network,
                        hooks: nil,
                        createdAt: agent?.createdAt ?? Date()
                    )
                    onSave(newAgent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || systemPrompt.isEmpty)
            }
            .padding()
            .background(ClaudeTheme.surfaceSecondary)
        }
        .frame(width: 480, height: 500)
    }
}
