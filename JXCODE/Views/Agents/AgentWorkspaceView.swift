import SwiftUI
import JXCODECore

struct AgentWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    @State private var taskText = ""
    @State private var selectedProjectPath = ""
    @State private var runLog = ""
    @State private var timer: Timer? = nil
    @State private var showingEditSheet = false

    var body: some View {
        Group {
            if let selectionId = windowState.selectedAgentId {
                if let agent = appState.agents.first(where: { $0.id == selectionId }) {
                    agentWorkspace(for: agent)
                } else if let run = appState.agentRuns.first(where: { $0.id == selectionId }) {
                    runHistoryWorkspace(for: run)
                } else {
                    noSelectionPlaceholder
                }
            } else {
                noSelectionPlaceholder
            }
        }
        .background(ClaudeTheme.background)
        .onAppear {
            initializeDefaults()
        }
        .onChange(of: windowState.selectedAgentId) { _, _ in
            initializeDefaults()
        }
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - Agent Execution Workspace

    private func agentWorkspace(for agent: Agent) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text(agent.icon)
                    .font(.system(size: ClaudeTheme.size(24)))
                    .padding(8)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    
                    Text("Model: \(agent.model)")
                        .font(.subheadline)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer()

                Button("Edit Agent") {
                    showingEditSheet = true
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(ClaudeTheme.surfaceElevated)

            ClaudeThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // System instructions display
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions")
                            .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .textCase(.uppercase)

                        Text(agent.systemPrompt)
                            .font(.subheadline)
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    // Setup task run parameters
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Configure Run")
                            .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .textCase(.uppercase)

                        Picker("Target Project", selection: $selectedProjectPath) {
                            Text("Select a Project...").tag("")
                            ForEach(appState.projects) { p in
                                Text(p.name).tag(p.path)
                            }
                        }
                        .pickerStyle(.menu)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Task Prompt")
                                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                .foregroundStyle(ClaudeTheme.textSecondary)

                            TextEditor(text: $taskText)
                                .font(.system(size: ClaudeTheme.size(13)))
                                .frame(height: 100)
                                .padding(6)
                                .border(ClaudeTheme.surfaceSecondary, width: 1)
                                .background(ClaudeTheme.surfaceSecondary)
                        }
                    }
                    .padding(16)
                    .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

                    // Execute Button
                    Button {
                        Task {
                            await appState.executeAgent(agent: agent, task: taskText, projectPath: selectedProjectPath)
                            // Switch selection to the newly started run
                            if let newRun = appState.agentRuns.first {
                                windowState.selectedAgentId = newRun.id
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Execute Background Agent")
                        }
                        .font(.headline)
                        .foregroundStyle(ClaudeTheme.textOnAccent)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClaudeTheme.accent)
                    .disabled(selectedProjectPath.isEmpty || taskText.isEmpty)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AgentEditSheet(agent: agent) { updated in
                Task { await appState.updateAgent(updated) }
            }
        }
    }

    // MARK: - Run Log Workspace

    private func runHistoryWorkspace(for run: AgentRun) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text(run.agentIcon)
                    .font(.system(size: ClaudeTheme.size(20)))
                    .padding(6)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(run.agentName)
                        .font(.headline)
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    
                    Text("Task: \(run.task)")
                        .font(.subheadline)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                // Status Pill
                HStack(spacing: 6) {
                    if run.status == "running" {
                        ProgressView().controlSize(.mini)
                    }
                    Text(run.status.capitalized)
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusColor(run.status).opacity(0.15))
                .foregroundStyle(statusColor(run.status))
                .clipShape(Capsule())
            }
            .padding(16)
            .background(ClaudeTheme.surfaceElevated)

            ClaudeThemeDivider()

            // Console output
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Console Output")
                        .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("Project: \(run.projectPath)")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runLog)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .id("LogEnd")
                    }
                    .background(Color.black.opacity(0.15))
                    .border(ClaudeTheme.surfaceSecondary, width: 1)
                    .padding([.horizontal, .bottom], 16)
                    .onChange(of: runLog) { _, _ in
                        proxy.scrollTo("LogEnd", anchor: .bottom)
                    }
                }
            }
        }
        .onAppear {
            loadRunLog(runId: run.id)
            if run.status == "running" {
                startTimer(for: run.id)
            }
        }
        .onChange(of: run.status) { _, newStatus in
            if newStatus != "running" {
                stopTimer()
                loadRunLog(runId: run.id)
            }
        }
    }

    // MARK: - Helpers

    private func initializeDefaults() {
        stopTimer()
        runLog = ""
        
        guard let selectionId = windowState.selectedAgentId else { return }
        
        if let agent = appState.agents.first(where: { $0.id == selectionId }) {
            taskText = agent.defaultTask ?? ""
            if selectedProjectPath.isEmpty {
                selectedProjectPath = windowState.selectedProject?.path ?? appState.projects.first?.path ?? ""
            }
        } else if let run = appState.agentRuns.first(where: { $0.id == selectionId }) {
            loadRunLog(runId: run.id)
            if run.status == "running" {
                startTimer(for: run.id)
            }
        }
    }

    private func loadRunLog(runId: UUID) {
        Task {
            let log = await appState.persistence.readAgentRunLog(runId: runId)
            await MainActor.run {
                self.runLog = log
            }
        }
    }

    private func startTimer(for runId: UUID) {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            loadRunLog(runId: runId)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return ClaudeTheme.accent
        case "completed": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: ClaudeTheme.size(48)))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Text("Background Agents Panel")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)

            Text("Select an agent or view previous execution logs from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
