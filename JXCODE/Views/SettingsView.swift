import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Settings Sheet

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var showUserManual = false

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general = "General"
        case session = "Session"
        case network = "Network"
        case customization = "Customization"
        case developer = "Developer"
        case account = "Account"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .session: "bubble.left.and.bubble.right"
            case .network: "network"
            case .customization: "paintbrush"
            case .developer: "wrench"
            case .account: "person.circle"
            }
        }
        var subItems: [SettingsTabItem] {
            switch self {
            case .general: [.general, .appearance]
            case .session: [.message, .permissions]
            case .network: [.proxy]
            case .customization: [.claudeMd, .commands, .shortcuts, .hooks, .environment]
            case .developer: [.advanced, .storage, .diagnostics]
            case .account: [.usage]
            }
        }
    }

    enum SettingsTabItem: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case message = "Chat"
        case permissions = "Permissions"
        case proxy = "Proxy"
        case claudeMd = "CLAUDE.MD"
        case commands = "Commands"
        case shortcuts = "Shortcuts"
        case hooks = "Hooks"
        case environment = "Environment"
        case advanced = "Advanced"
        case storage = "Storage"
        case diagnostics = "Diagnostics"
        case usage = "Usage"
        case projects = "Projects"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .message: "message"
            case .permissions: "shield"
            case .proxy: "network"
            case .claudeMd: "doc.text"
            case .commands: "terminal"
            case .shortcuts: "bolt"
            case .hooks: "link"
            case .environment: "globe"
            case .advanced: "wrench"
            case .storage: "externaldrive"
            case .diagnostics: "stethoscope"
            case .usage: "chart.bar"
            case .projects: "folder"
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
        .sheet(isPresented: $showUserManual) {
            UserManualView()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        guard let category = selectedCategory, let firstTab = category.subItems.first else {
            Text("Select a setting").foregroundStyle(.secondary)
            return
        }
        // Use the first tab of the selected category as the default detail
        tabContent(for: firstTab)
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTabItem) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab(showUserManual: $showUserManual)
        case .appearance:
            PaseoAppearanceTab()
        case .message:
            ChatSettingsTab()
        case .permissions:
            PermissionsSettingsTab()
        case .proxy:
            ProxySettingsTab()
        case .claudeMd:
            ClaudeMdSettingsTab()
        case .commands:
            CommandsSettingsTab()
        case .shortcuts:
            ShortcutManagerView(isEmbedded: true)
        case .hooks:
            HooksSettingsTab()
        case .environment:
            EnvironmentSettingsTab()
        case .advanced:
            AdvancedSettingsTab()
        case .storage:
            StorageSettingsTab()
        case .diagnostics:
            PaseoDiagnosticsTab()
        case .usage:
            UsageDashboardView()
        case .projects:
            PaseoProjectsTab()
        }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Binding var showUserManual: Bool
    @State private var showSkillMarket = false
    @State private var showThemePicker = false

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                themeSection
                Divider()
                fontSizeSection
                Divider()
                notificationsSection(appState: $appState.notificationsEnabled)
                Divider()
                inspectorLayoutSection
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    skillMarketSection
                    helpSection
                    sourceCodeSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleSection(title: LocalizedStringKey, label: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: ClaudeTheme.size(13)))
                    Text(detail).font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch)
        }
    }

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Size").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            fontSizeRow(label: "Interface", value: appState.fontSizeAdjustment, onDecrease: { appState.decreaseFontSize() }, onIncrease: { appState.increaseFontSize() }, onReset: { appState.fontSizeAdjustment = 0 })
            fontSizeRow(label: "Messages", value: appState.messageFontSizeAdjustment, onDecrease: { appState.decreaseMessageFontSize() }, onIncrease: { appState.increaseMessageFontSize() }, onReset: { appState.messageFontSizeAdjustment = 0 })
        }
    }

    private func fontSizeRow(label: LocalizedStringKey, value: Int, onDecrease: @escaping () -> Void, onIncrease: @escaping () -> Void, onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: ClaudeTheme.size(12))).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Button(action: onDecrease) { Image(systemName: "minus").frame(width: 26, height: 26).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)) }.buttonStyle(.plain).disabled(value <= ThemeStore.minFontSizeAdjustment)
            Group {
                if value == 0 { Text("Default") } else { Text(verbatim: value > 0 ? "+\(value)" : "\(value)") }
            }.font(.system(size: ClaudeTheme.size(13), weight: .medium)).frame(minWidth: 48, alignment: .center)
            Button(action: onIncrease) { Image(systemName: "plus").frame(width: 26, height: 26).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)) }.buttonStyle(.plain).disabled(value >= ThemeStore.maxFontSizeAdjustment)
            if value != 0 { Button("Reset", action: onReset).buttonStyle(.plain).font(.system(size: ClaudeTheme.size(12))).foregroundStyle(ClaudeTheme.accent) }
        }
    }

    private var notificationsSection: some View {
        toggleSection(title: "Notifications", label: "Notify when response completes", detail: "Sends a system notification while JXCODE is in the background.", isOn: appState.notificationsEnabled)
    }

    private var inspectorLayoutSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Panel Layout").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Text("Choose where the memo and terminal panel is docked.").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
            Picker("", selection: $appState.inspectorPosition) {
                Text("Right").tag(InspectorPosition.right)
                Text("Bottom").tag(InspectorPosition.bottom)
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
            Toggle(isOn: $appState.inspectorShowBoth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show memo and terminal together").font(.system(size: ClaudeTheme.size(13)))
                    Text("Splits the panel in two.").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch)
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme").font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Button { showThemePicker.toggle() } label: {
                HStack(spacing: 8) {
                    Circle().fill(appState.selectedTheme.colors.accent).frame(width: 10, height: 10)
                    Text(appState.selectedTheme.displayName).font(.system(size: ClaudeTheme.size(13))).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: ClaudeTheme.size(10))).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            appState.selectedTheme = theme
                            showThemePicker = false
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(theme.colors.accent).frame(width: 10, height: 10)
                                Text(theme.displayName).font(.system(size: ClaudeTheme.size(13)))
                                Spacer()
                                if appState.selectedTheme == theme { Image(systemName: "checkmark").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary) }
                            }.padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }.padding(4).frame(minWidth: 220)
            }
        }
    }

    private var skillMarketSection: some View {
        Button { showSkillMarket = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile").font(.system(size: ClaudeTheme.size(14))).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skill Marketplace").font(.system(size: ClaudeTheme.size(13))).foregroundStyle(.primary)
                    Text("Browse and manage Claude Code skills").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 10).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }.buttonStyle(.plain).sheet(isPresented: $showSkillMarket) { SkillMarketView(isEmbedded: false) }
    }

    private var sourceCodeSection: some View {
        Link(destination: URL(string: "https://github.com/ttnear/JXCODE")!) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: ClaudeTheme.size(14))).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Source").font(.system(size: ClaudeTheme.size(13))).foregroundStyle(.primary)
                    Text(verbatim: "github.com/ttnear/JXCODE").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 10).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var helpSection: some View {
        Button { showUserManual = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill").font(.system(size: ClaudeTheme.size(14))).frame(width: 20)
                Text("User Guide").font(.system(size: ClaudeTheme.size(13))).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 10).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }.buttonStyle(.plain)
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
