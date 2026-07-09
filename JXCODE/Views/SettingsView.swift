import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Settings Sheet

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedCategory: SettingsCategory? = .general
    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general = "General"
        case network = "Network"
        case developer = "Developer"
        case account = "Account"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .network: "network"
            case .developer: "wrench"
            case .account: "person.circle"
            }
        }
        var subItems: [SettingsTabItem] {
            switch self {
            case .general: [.appearance, .message, .permissions]
            case .network: [.proxy, .environment]
            case .developer: [.advanced, .commands, .shortcuts, .hooks, .claudeMd, .storage]
            case .account: [.usage, .diagnostics]
            }
        }
    }

    enum SettingsTabItem: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case message = "Chat"
        case permissions = "Permissions"
        case proxy = "Proxy"
        case environment = "Environment"
        case advanced = "Advanced"
        case commands = "Commands"
        case shortcuts = "Shortcuts"
        case hooks = "Hooks"
        case claudeMd = "CLAUDE.MD"
        case storage = "Storage"
        case usage = "Usage"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .message: "message"
            case .permissions: "shield"
            case .proxy: "network"
            case .environment: "globe"
            case .advanced: "wrench"
            case .commands: "terminal"
            case .shortcuts: "bolt"
            case .hooks: "link"
            case .claudeMd: "doc.text"
            case .storage: "externaldrive"
            case .usage: "chart.bar"
            case .diagnostics: "stethoscope"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases) { category in
                Section {
                    ForEach(category.subItems) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: ClaudeTheme.size(12)))
                            .tag(item)
                            .onTapGesture { selectedCategory = category }
                    }
                } header: {
                    Label(category.rawValue, systemImage: category.icon)
                        .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
        } detail: {
            detailContent
        }
        .frame(width: 850, height: 620)
        .focusable(false)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let category = selectedCategory, let firstTab = category.subItems.first {
            tabContent(for: firstTab)
        } else {
            Text("Select a setting").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTabItem) -> some View {
        switch tab {
        case .appearance:
            PaseoAppearanceTab()
        case .message:
            ChatSettingsTab()
        case .permissions:
            PermissionsSettingsTab()
        case .proxy:
            ProxySettingsTab()
        case .environment:
            EnvironmentSettingsTab()
        case .advanced:
            AdvancedSettingsTab()
        case .commands:
            CommandsSettingsTab()
        case .shortcuts:
            ShortcutManagerView(isEmbedded: true)
        case .hooks:
            HooksSettingsTab()
        case .claudeMd:
            ClaudeMdSettingsTab()
        case .storage:
            StorageSettingsTab()
        case .usage:
            UsageDashboardView()
        case .diagnostics:
            PaseoDiagnosticsTab()
        }
    }
}

// MARK: - Chat Settings Tab

struct ChatSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                modelSection(selectedModel: $appState.selectedModel)
                Divider()
                permissionModeSection
                Divider()
                effortSection
                Divider()
                focusModeSection
                Divider()
                autoPreviewSection
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modelSection(selectedModel: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default Model").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Text("Used for new sessions. You can override the model per session from the toolbar.").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
            Picker("", selection: selectedModel) {
                ForEach(AppState.availableModels, id: \.self) { model in
                    Text(AppState.modelDisplayName(model)).tag(model)
                }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
            Text(AppState.modelDescription(selectedModel.wrappedValue)).font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
        }
    }

    private var permissionModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Permission Mode").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Text("Used for new sessions.").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
            Picker("", selection: $appState.permissionMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.displayName)).tag(mode)
                }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    private var effortSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Default Effort Level").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Picker("", selection: $appState.selectedEffort) {
                Text("Auto").tag("auto")
                ForEach(AppState.availableEfforts, id: \.self) { effort in
                    Text(effortDisplayName(effort)).tag(effort)
                }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    private var focusModeSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Focus Mode").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Toggle(isOn: $appState.focusMode) { Text("Enable Focus Mode") }.toggleStyle(.switch).fixedSize()
        }
    }

    private var autoPreviewSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Auto-preview Attachments").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("URL links", isOn: $appState.autoPreviewSettings.url)
                Toggle("File paths", isOn: $appState.autoPreviewSettings.filePath)
                Toggle("Images", isOn: $appState.autoPreviewSettings.image)
                Toggle("Long text (200+ characters)", isOn: $appState.autoPreviewSettings.longText)
            }.toggleStyle(.checkbox)
        }
    }

    private func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return effort.capitalized
        }
    }
}
