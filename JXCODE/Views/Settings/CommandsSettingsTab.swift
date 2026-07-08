import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Commands Settings Tab

public struct CommandsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var commands: [CustomCommand] = []
    @State private var showAddSheet = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ClaudeThemeDivider()
            listContent
        }
        .onAppear(perform: loadCommands)
    }

    private var header: some View {
        HStack {
            Text("Custom Commands")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Spacer()
            Button(action: { showAddSheet = true }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .sheet(isPresented: $showAddSheet) {
            CommandEditView(onSave: { cmd in commands.append(cmd); saveCommands() })
        }
    }

    private var listContent: some View {
        Group {
            if commands.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No custom commands yet")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(commands) { cmd in
                        HStack(spacing: 10) {
                            Text(cmd.icon)
                                .font(.system(size: ClaudeTheme.size(16)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/\(cmd.name)")
                                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                                Text(cmd.action)
                                    .font(.system(size: ClaudeTheme.size(10)))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { cmd.isEnabled },
                                set: { updateCommand(cmd, isEnabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteCommands)
                }
                .listStyle(.plain)
            }
        }
    }

    private func updateCommand(_ cmd: CustomCommand, isEnabled: Bool) {
        if let i = commands.firstIndex(where: { $0.id == cmd.id }) {
            commands[i].isEnabled = isEnabled
            saveCommands()
        }
    }

    private func deleteCommands(at offsets: IndexSet) {
        commands.remove(atOffsets: offsets)
        saveCommands()
    }

    private func loadCommands() {
        guard let data = UserDefaults.standard.data(forKey: "jxcode.customCommands"),
              let decoded = try? JSONDecoder().decode([CustomCommand].self, from: data) else { return }
        commands = decoded
    }

    private func saveCommands() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: "jxcode.customCommands")
    }
}

public struct CustomCommand: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var action: String
    public var icon: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, action: String, icon: String = "🔧", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.action = action
        self.icon = icon
        self.isEnabled = isEnabled
    }
}

struct CommandEditView: View {
    let onSave: (CustomCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var action = ""
    @State private var icon = "🔧"

    let icons = ["🔧", "🚀", "📦", "🔄", "🔍", "💻", "📝", "🛠️", "⚙️", "🎯"]

    var body: some View {
        VStack(spacing: 16) {
            Text("New Command")
                .font(.headline)
            Form {
                TextField("Command name (no slash)", text: $name)
                TextField("Action (command or prompt)", text: $action, axis: .vertical)
                    .lineLimit(3...6)
                Picker("Icon", selection: $icon) {
                    ForEach(icons, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let cmd = CustomCommand(name: name.lowercased(), action: action, icon: icon)
                    onSave(cmd)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || action.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
