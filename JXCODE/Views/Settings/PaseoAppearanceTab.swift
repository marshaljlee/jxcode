import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Paseo Appearance Tab

public struct PaseoAppearanceTab: View {
    @Environment(AppState.self) private var appState
    @State private var showThemePicker = false
    @State private var showLineNumbers = true
    @State private var showFileIcons = true
    @State private var interfaceFontSize: Double = 11
    @State private var messageFontSize: Double = 11
    @State private var customAccentColor: Color = .accentColor
    @State private var useCustomAccent = false

    private static let customAccentKey = "jxcode.customAccentColor"
    private static let useCustomAccentKey = "jxcode.useCustomAccent"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                themeSection
                Divider()
                fontSizeSection
                Divider()
                accentSection
                Divider()
                displayOptions
                Divider()
                previewSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadSettings)
    }

    // MARK: - Theme Selector

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

    // MARK: - Font Size Sliders

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Font Size")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 14) {
                interfaceFontSizeSlider
                messageFontSizeSlider
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var interfaceFontSizeSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Interface")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(interfaceFontSize)) pt")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(
                value: $interfaceFontSize,
                in: 9...18,
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text("A").font(.system(size: ClaudeTheme.size(9)))
            } maximumValueLabel: {
                Text("A").font(.system(size: ClaudeTheme.size(14)))
            }
            .tint(ClaudeTheme.accent)
            .onChange(of: interfaceFontSize) { _, newValue in
                let adjustment = Int(newValue) - 11
                appState.fontSizeAdjustment = adjustment
            }
        }
    }

    private var messageFontSizeSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Messages")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(messageFontSize)) pt")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(
                value: $messageFontSize,
                in: 9...18,
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text("A").font(.system(size: ClaudeTheme.size(9)))
            } maximumValueLabel: {
                Text("A").font(.system(size: ClaudeTheme.size(14)))
            }
            .tint(ClaudeTheme.accent)
            .onChange(of: messageFontSize) { _, newValue in
                let adjustment = Int(newValue) - 11
                appState.messageFontSizeAdjustment = adjustment
            }
        }
    }

    // MARK: - Custom Accent Color

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent Color")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 12) {
                Toggle(isOn: $useCustomAccent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Custom Accent")
                            .font(.system(size: ClaudeTheme.size(12)))
                        Text("Override the theme accent with a custom color")
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: useCustomAccent) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: Self.useCustomAccentKey)
                    if newValue {
                        applyCustomAccent(customAccentColor)
                    } else {
                        resetCustomAccent()
                    }
                }

                if useCustomAccent {
                    HStack(spacing: 12) {
                        ColorPicker("", selection: $customAccentColor, supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 32, height: 32)

                        RoundedRectangle(cornerRadius: 6)
                            .fill(customAccentColor)
                            .frame(width: 48, height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                            )

                        Text(customAccentColor.hexString)
                            .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Reset") {
                            useCustomAccent = false
                            resetCustomAccent()
                        }
                        .controlSize(.small)
                        .font(.system(size: ClaudeTheme.size(11)))
                    }
                    .padding(10)
                    .background(ClaudeTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: customAccentColor) { _, newColor in
                        persistCustomAccent(newColor)
                        applyCustomAccent(newColor)
                    }
                }
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Display Options

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

    // MARK: - Preview

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

    // MARK: - Helpers

    private func loadSettings() {
        showLineNumbers = UserDefaults.standard.bool(forKey: "jxcode.showLineNumbers")
        showFileIcons = UserDefaults.standard.bool(forKey: "jxcode.showFileIcons")
        useCustomAccent = UserDefaults.standard.bool(forKey: Self.useCustomAccentKey)
        if let hexData = UserDefaults.standard.string(forKey: Self.customAccentKey) {
            customAccentColor = Color(hex: hexData)
        }
        if useCustomAccent {
            applyCustomAccent(customAccentColor)
        }

        // Rebuild font-size from the adjustment stored in appState
        interfaceFontSize = Double(11 + appState.fontSizeAdjustment)
        messageFontSize = Double(11 + appState.messageFontSizeAdjustment)
    }

    private func persistCustomAccent(_ color: Color) {
        UserDefaults.standard.set(color.hexString, forKey: Self.customAccentKey)
    }

    private func applyCustomAccent(_ color: Color) {
        // Store a marker that triggers theme-aware consumers to read from
        // UserDefaults instead of the theme enum. Components that observe
        // ThemeStore.shared.colors will pick this up via a post.
        UserDefaults.standard.set(color.hexString, forKey: Self.customAccentKey)
        NotificationCenter.default.post(name: .jxcodeThemeDidChange, object: nil)
    }

    private func resetCustomAccent() {
        UserDefaults.standard.removeObject(forKey: Self.customAccentKey)
        NotificationCenter.default.post(name: .jxcodeThemeDidChange, object: nil)
    }
}
