import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Paseo Appearance Tab

public struct PaseoAppearanceTab: View {
    @Environment(AppState.self) private var appState
    @State private var showThemePicker = false
    @State private var showLineNumbers = true
    @State private var showFileIcons = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                themeSection
                Divider()
                displayOptions
                Divider()
                previewSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            showLineNumbers = UserDefaults.standard.bool(forKey: "jxcode.showLineNumbers")
            showFileIcons = UserDefaults.standard.bool(forKey: "jxcode.showFileIcons")
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Button { showThemePicker.toggle() } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.selectedTheme.colors.accent)
                        .frame(width: 10, height: 10)
                    Text(appState.selectedTheme.displayName)
                        .font(.system(size: ClaudeTheme.size(13)))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
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
                                if appState.selectedTheme == theme {
                                    Image(systemName: "checkmark").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4).frame(minWidth: 220)
            }
        }
    }

    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Toggle(isOn: $showLineNumbers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Line Numbers")
                        .font(.system(size: ClaudeTheme.size(12)))
                    Text("Display line numbers in the file viewer")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: showLineNumbers) { _, v in UserDefaults.standard.set(v, forKey: "jxcode.showLineNumbers") }

            Toggle(isOn: $showFileIcons) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show File Icons")
                        .font(.system(size: ClaudeTheme.size(12)))
                    Text("Display file type icons in the sidebar")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: showFileIcons) { _, v in UserDefaults.standard.set(v, forKey: "jxcode.showFileIcons") }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("The current theme affects all panels, messages, and code views.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ClaudeTheme.surfacePrimary)
                    .frame(width: 80, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeTheme.border, lineWidth: 1))
                RoundedRectangle(cornerRadius: 8)
                    .fill(ClaudeTheme.surfaceSecondary)
                    .frame(width: 80, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeTheme.border, lineWidth: 1))
                RoundedRectangle(cornerRadius: 8)
                    .fill(ClaudeTheme.surfaceTertiary)
                    .frame(width: 80, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeTheme.border, lineWidth: 1))
            }
        }
    }
}
