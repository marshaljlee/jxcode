import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Hooks Settings Tab

public struct HooksSettingsTab: View {
    @State private var hooksConfiguration: [HookConfig] = HookConfig.defaults
    @State private var selectedHookIndex: Int = 0

    public init() {}

    public var body: some View {
        HSplitView {
            sidebar
            detailView
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var sidebar: some View {
        List(Array(hooksConfiguration.enumerated()), id: \.element.id) { index, hook in
            HStack(spacing: 8) {
                Circle()
                    .fill(hook.isEnabled ? ClaudeTheme.statusSuccess : ClaudeTheme.textTertiary)
                    .frame(width: 8, height: 8)
                Text(hook.displayName)
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { selectedHookIndex = index }
            .listRowBackground(selectedHookIndex == index ? ClaudeTheme.surfaceTertiary : Color.clear)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
    }

    private var detailView: some View {
        guard hooksConfiguration.indices.contains(selectedHookIndex) else {
            return AnyView(Text("Select a hook"))
        }
        let binding = Binding<HookConfig>(
            get: { hooksConfiguration[selectedHookIndex] },
            set: { hooksConfiguration[selectedHookIndex] = $0 }
        )
        return AnyView(HookDetailView(config: binding, onSave: saveSettings))
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(hooksConfiguration) {
            UserDefaults.standard.set(data, forKey: "jxcode.hooksConfiguration")
        }
    }
}

public struct HookConfig: Identifiable, Codable {
    public var id: String
    public var displayName: String
    public var description: String
    public var script: String
    public var isEnabled: Bool

    public static let defaults: [HookConfig] = [
        HookConfig(id: "preTask", displayName: "Before Task", description: "Runs before each task execution", script: "", isEnabled: false),
        HookConfig(id: "postTask", displayName: "After Task", description: "Runs after each task completes", script: "", isEnabled: false),
        HookConfig(id: "preEdit", displayName: "Before Edit", description: "Runs before file modifications", script: "", isEnabled: false),
        HookConfig(id: "postEdit", displayName: "After Edit", description: "Runs after file modifications", script: "", isEnabled: false),
        HookConfig(id: "sessionStart", displayName: "Session Start", description: "Runs when a session begins", script: "", isEnabled: false),
        HookConfig(id: "sessionEnd", displayName: "Session End", description: "Runs when a session ends", script: "", isEnabled: false),
    ]
}

private struct HookDetailView: View {
    @Binding var config: HookConfig
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(config.displayName)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))

            Text(config.description)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            Toggle(isOn: $config.isEnabled) {
                Text("Enable this hook")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .toggleStyle(.switch)
            .onChange(of: config.isEnabled) { _, _ in onSave() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Script / Command")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))

                TextEditor(text: $config.script)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(ClaudeTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeTheme.border, lineWidth: 1))
            }
            .onChange(of: config.script) { _, _ in onSave() }

            Spacer()
        }
        .padding(20)
    }
}
