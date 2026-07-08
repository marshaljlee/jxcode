import SwiftUI
import JXCODECore
import JXCODEChatKit
import UniformTypeIdentifiers

// MARK: - Advanced Settings Tab

public struct AdvancedSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var claudeBinaryPath: String = ""
    @State private var nodePath: String = ""
    @State private var nvmPath: String = ""
    @State private var maxTokens: Double = 4096
    @State private var isTelemetryEnabled: Bool = true
    @State private var commandTimeout: Double = 300

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                claudeBinarySection
                Divider()
                environmentPathsSection
                Divider()
                performanceSection
                Divider()
                telemetrySection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadSettings)
    }

    // MARK: - Claude Binary Path

    private var claudeBinarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Binary Path")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Path to the Claude Code CLI executable. Leave empty to use the system default.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("/usr/local/bin/claude", text: $claudeBinaryPath)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                    )
                    .font(.system(size: ClaudeTheme.size(12)))
                    .onChange(of: claudeBinaryPath) { _, _ in saveSettings() }

                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.unixExecutable]
                    if panel.runModal() == .OK, let url = panel.url {
                        claudeBinaryPath = url.path
                        saveSettings()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Environment Paths

    private var environmentPathsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment Paths")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Custom paths for Node.js and NVM. Used when Claude Code spawns subprocesses that depend on these tools.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                labeledTextField(
                    label: "Node.js",
                    text: $nodePath,
                    placeholder: "/usr/local/bin/node",
                    onChange: saveSettings
                )

                labeledTextField(
                    label: "NVM Path",
                    text: $nvmPath,
                    placeholder: "/Users/username/.nvm/nvm.sh",
                    onChange: saveSettings
                )
            }
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Control response length and command execution time limits.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Max Tokens: \(Int(maxTokens))")
                    .font(.system(size: ClaudeTheme.size(11)))

                Slider(value: $maxTokens, in: 1024...32768, step: 1024) {
                    Text("Max Tokens")
                }
                .onChange(of: maxTokens) { _, _ in saveSettings() }

                Text("Command Timeout: \(Int(commandTimeout))s")
                    .font(.system(size: ClaudeTheme.size(11)))

                Slider(value: $commandTimeout, in: 30...600, step: 30) {
                    Text("Timeout")
                }
                .onChange(of: commandTimeout) { _, _ in saveSettings() }
            }
        }
    }

    // MARK: - Telemetry

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telemetry")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Toggle(isOn: $isTelemetryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send anonymous usage data")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Helps improve JXCODE. No personal data is collected.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: isTelemetryEnabled) { _, _ in saveSettings() }
        }
    }

    // MARK: - Helpers

    private func labeledTextField(label: String, text: Binding<String>, placeholder: String, onChange: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 72, alignment: .trailing)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                )
                .font(.system(size: ClaudeTheme.size(12)))
                .onChange(of: text.wrappedValue) { _, _ in onChange() }
        }
    }

    // MARK: - Persistence

    private func loadSettings() {
        claudeBinaryPath = UserDefaults.standard.string(forKey: "jxcode.claudeBinaryPath") ?? ""
        nodePath = UserDefaults.standard.string(forKey: "jxcode.nodePath") ?? ""
        nvmPath = UserDefaults.standard.string(forKey: "jxcode.nvmPath") ?? ""
        maxTokens = UserDefaults.standard.object(forKey: "jxcode.maxTokens") as? Double ?? 4096
        isTelemetryEnabled = UserDefaults.standard.object(forKey: "jxcode.telemetryEnabled") as? Bool ?? true
        commandTimeout = UserDefaults.standard.object(forKey: "jxcode.commandTimeout") as? Double ?? 300
    }

    private func saveSettings() {
        UserDefaults.standard.set(claudeBinaryPath, forKey: "jxcode.claudeBinaryPath")
        UserDefaults.standard.set(nodePath, forKey: "jxcode.nodePath")
        UserDefaults.standard.set(nvmPath, forKey: "jxcode.nvmPath")
        UserDefaults.standard.set(maxTokens, forKey: "jxcode.maxTokens")
        UserDefaults.standard.set(isTelemetryEnabled, forKey: "jxcode.telemetryEnabled")
        UserDefaults.standard.set(commandTimeout, forKey: "jxcode.commandTimeout")
    }
}
