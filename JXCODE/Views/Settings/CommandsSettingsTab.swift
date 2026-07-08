import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Commands Settings Tab

/// A read-only detail sheet for a built-in slash command (description, flags, aliases).
private struct BuiltInCommandDetailSheet: View {
    let command: SlashCommand
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.command)
                        .font(.system(size: ClaudeTheme.size(16), weight: .bold, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text(command.description)
                        .font(.system(size: ClaudeTheme.size(13)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                Spacer()
            }
            .padding(20)

            ClaudeThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = command.detailDescription {
                        Text(detail)
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !command.aliases.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aliases")
                                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                ForEach(command.aliases, id: \.self) { alias in
                                    Text("/\(alias)")
                                        .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Flags")
                            .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            flagBadge(icon: "text.cursor", label: "Accepts Input", active: command.acceptsInput)
                            flagBadge(icon: "terminal", label: "Interactive", active: command.isInteractive)
                        }
                    }
                }
                .padding(20)
            }

            ClaudeThemeDivider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(16)
        }
        .frame(width: 480, height: 400)
        .background(ClaudeTheme.background)
    }

    private func flagBadge(icon: String, label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: ClaudeTheme.size(10)))
            Text(label)
                .font(.system(size: ClaudeTheme.size(11)))
        }
        .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.4))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            active
                ? Color.accentColor.opacity(0.08)
                : Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

public struct CommandsSettingsTab: View {
    @State private var searchText = ""
    @State private var selectedCommand: SlashCommand?
    @State private var editingCommand: SlashCommand?
    @State private var isAddingNew = false
    @State private var showResetAlert = false
    @State private var showImportResult = false
    @State private var importResultMessage = ""
    @State private var importSuccess = false

    public init() {}

    private var filteredCommands: [SlashCommand] {
        let cmds = SlashCommandRegistry.commands
        if searchText.isEmpty { return cmds }
        let q = searchText.lowercased()
        return cmds.filter {
            $0.name.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.aliases.contains(where: { $0.lowercased().contains(q) })
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            searchBarView
            commandListContent
        }
        .sheet(item: $editingCommand) { cmd in
            CommandEditSheet(
                command: cmd,
                isDefault: SlashCommandRegistry.isDefault(name: cmd.name),
                onSave: { updated in saveCommand(original: cmd, updated: updated) },
                onDelete: { deleteCommand(cmd) }
            )
        }
        .sheet(isPresented: $isAddingNew) {
            CommandEditSheet(
                command: nil,
                isDefault: false,
                onSave: { addCommand($0) }
            )
        }
        .alert("Reset Default Commands", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) { resetDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All modified default commands will be restored to their original state.")
        }
        .alert(importSuccess ? "Import Succeeded" : "Import Failed", isPresented: $showImportResult) {
            Button("OK") {}
        } message: {
            Text(importResultMessage)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Commands")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("\(SlashCommandRegistry.commands.count) commands (\(SlashCommandRegistry.customCommandCount) custom)")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button { showResetAlert = true } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reset default commands")

            Button { exportCommands() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Export custom commands")

            Button { importCommands() } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Import custom commands")

            Button { isAddingNew = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Search Bar

    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
            TextField("Search commands...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: ClaudeTheme.size(13)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Command List

    private var commandListContent: some View {
        Group {
            if filteredCommands.isEmpty {
                emptyState
            } else {
                List {
                    builtInCommandsSection
                    customCommandsSection
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var builtInCommandsSection: some View {
        let builtIn = filteredCommands.filter { SlashCommandRegistry.isDefault(name: $0.name) }
        if !builtIn.isEmpty {
            Section {
                ForEach(builtIn) { cmd in
                    commandRow(cmd)
                        .contextMenu { builtInCommandContextMenu(cmd) }
                        .onTapGesture { selectedCommand = cmd }
                }
                .sheet(item: $selectedCommand) { cmd in
                    BuiltInCommandDetailSheet(command: cmd)
                }
            } header: {
                Text("Built-in Commands")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
    }

    @ViewBuilder
    private var customCommandsSection: some View {
        let custom = filteredCommands.filter { !SlashCommandRegistry.isDefault(name: $0.name) }
        Section {
            if custom.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: ClaudeTheme.size(20)))
                            .foregroundStyle(.tertiary)
                        Text("No custom commands yet")
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(custom) { cmd in
                    customCommandRow(cmd)
                }
                .onDelete(perform: deleteCustomCommands)
            }
        } header: {
            HStack {
                Text("Custom Commands")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !custom.isEmpty {
                    Text("swipe to delete")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Command Row

    private func commandRow(_ cmd: SlashCommand) -> some View {
        let isEnabled = SlashCommandRegistry.isEnabled(name: cmd.name)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cmd.command)
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold, design: .monospaced))
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

                    if cmd.acceptsInput {
                        badge("accepts input")
                    }
                    if cmd.isInteractive {
                        badge("terminal")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(cmd.description)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { SlashCommandRegistry.isEnabled(name: cmd.name) },
                set: { newValue in
                    SlashCommandRegistry.setEnabled(name: cmd.name, newValue)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(isEnabled ? "Disable command" : "Enable command")
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    private func customCommandRow(_ cmd: SlashCommand) -> some View {
        let isEnabled = SlashCommandRegistry.isEnabled(name: cmd.name)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cmd.command)
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold, design: .monospaced))
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                }
                Text(cmd.description)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { SlashCommandRegistry.isEnabled(name: cmd.name) },
                set: { newValue in
                    SlashCommandRegistry.setEnabled(name: cmd.name, newValue)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(isEnabled ? "Disable command" : "Enable command")
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1.0 : 0.5)
        .onTapGesture { editingCommand = cmd }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ClaudeTheme.size(9)))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(NSColor.controlBackgroundColor), in: Capsule())
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func builtInCommandContextMenu(_ cmd: SlashCommand) -> some View {
        let isModified = SlashCommandRegistry.isModified(name: cmd.name)
        if isModified {
            Button("Restore Default") {
                if let original = SlashCommandRegistry.originalDefault(name: cmd.name) {
                    SlashCommandRegistry.modifyDefault(originalName: cmd.name, modified: original)
                }
            }
        }
        Button("Details") { selectedCommand = cmd }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "command")
                .font(.system(size: ClaudeTheme.size(32)))
                .foregroundStyle(.secondary)
            Text("No results found")
                .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                .foregroundStyle(.secondary)
            Text("Try a different search term")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func addCommand(_ cmd: SlashCommand) {
        SlashCommandRegistry.addCustomCommand(cmd)
    }

    private func saveCommand(original: SlashCommand, updated: SlashCommand) {
        if SlashCommandRegistry.isDefault(name: original.name) {
            SlashCommandRegistry.modifyDefault(originalName: original.name, modified: updated)
        } else {
            SlashCommandRegistry.replaceCustomCommand(name: original.name, with: updated)
        }
    }

    private func deleteCommand(_ cmd: SlashCommand) {
        guard !SlashCommandRegistry.isDefault(name: cmd.name) else { return }
        SlashCommandRegistry.removeCustomCommand(name: cmd.name)
    }

    private func deleteCustomCommands(at offsets: IndexSet) {
        let custom = SlashCommandRegistry.commands.filter { !SlashCommandRegistry.isDefault(name: $0.name) }
        for index in offsets {
            guard index < custom.count else { continue }
            SlashCommandRegistry.removeCustomCommand(name: custom[index].name)
        }
    }

    private func resetDefaults() {
        SlashCommandRegistry.resetAllDefaults()
    }

    private func exportCommands() {
        guard let data = SlashCommandRegistry.exportCommands() else { return }
        let panel = NSSavePanel()
        panel.title = "Export Slash Commands"
        panel.nameFieldStringValue = "slash_commands.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func importCommands() {
        let panel = NSOpenPanel()
        panel.title = "Import Slash Commands"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            DispatchQueue.main.async {
                if SlashCommandRegistry.importCommands(from: data) {
                    importSuccess = true
                    importResultMessage = "Imported \(SlashCommandRegistry.customCommandCount) custom commands."
                } else {
                    importSuccess = false
                    importResultMessage = "Invalid JSON format."
                }
                showImportResult = true
            }
        }
    }
}

// MARK: - Command Edit Sheet

public struct CommandEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let command: SlashCommand?
    let isDefault: Bool
    let onSave: (SlashCommand) -> Void
    var onDelete: (() -> Void)?

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var detailDescription: String = ""
    @State private var acceptsInput: Bool = false
    @State private var isInteractive: Bool = false

    public init(
        command: SlashCommand?,
        isDefault: Bool,
        onSave: @escaping (SlashCommand) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.command = command
        self.isDefault = isDefault
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var isEditing: Bool { command != nil }
    private var normalizedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop { $0 == "/" })
    }

    private var hasNameConflict: Bool {
        guard !normalizedName.isEmpty else { return false }
        if isEditing, let command, SlashCommandRegistry.namesMatch(normalizedName, command.name) {
            return false
        }
        if SlashCommandRegistry.isDefault(name: normalizedName) { return true }
        return SlashCommandRegistry.customCommandExists(name: normalizedName, excluding: command?.name)
    }

    private var isValid: Bool {
        !normalizedName.isEmpty &&
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !hasNameConflict
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Group {
                    if isEditing { Text("Edit Command") } else { Text("Add New Command") }
                }
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ClaudeTheme.size(16)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name
                    fieldSection("Name") {
                        HStack(spacing: 4) {
                            Text("/")
                                .font(.system(size: ClaudeTheme.size(14), weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            TextField("Command name (e.g. deploy)", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: ClaudeTheme.size(14), design: .monospaced))
                                .disabled(isDefault)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isDefault ? Color(NSColor.controlBackgroundColor) : Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                        )

                        if hasNameConflict {
                            Text("A command with this name already exists.")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(.red)
                        }
                    }

                    // Description
                    fieldSection("Description") {
                        TextField("Short description shown in the command picker", text: $description)
                            .textFieldStyle(.plain)
                            .font(.system(size: ClaudeTheme.size(14)))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                            )
                    }

                    // Detail description
                    fieldSection("Detail Description (optional)") {
                        TextEditor(text: $detailDescription)
                            .font(.system(size: ClaudeTheme.size(13)))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80, maxHeight: 150)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                            )
                    }

                    // Toggles
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Accepts Input")
                                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                                Text("Allows additional text to be entered after the command")
                                    .font(.system(size: ClaudeTheme.size(11)))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $acceptsInput)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Interactive (Terminal)")
                                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                                Text("Commands requiring TUI will run in the inline terminal")
                                    .font(.system(size: ClaudeTheme.size(11)))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $isInteractive)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            // Bottom buttons
            HStack {
                if isEditing && isDefault {
                    Button {
                        if let original = SlashCommandRegistry.originalDefault(name: command!.name) {
                            onSave(original)
                        }
                        dismiss()
                    } label: {
                        Text("Restore Default")
                            .font(.system(size: ClaudeTheme.size(13)))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }

                if isEditing && !isDefault {
                    Button(role: .destructive) {
                        onDelete?()
                        dismiss()
                    } label: {
                        Text("Delete")
                            .font(.system(size: ClaudeTheme.size(13)))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                Button(isEditing ? "Save" : "Add") {
                    let result = SlashCommand(
                        name: normalizedName,
                        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                        detailDescription: detailDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : detailDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                        acceptsInput: acceptsInput,
                        isInteractive: isInteractive
                    )
                    onSave(result)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 520)
        .onAppear {
            if let cmd = command {
                name = cmd.name
                description = cmd.description
                detailDescription = cmd.detailDescription ?? ""
                acceptsInput = cmd.acceptsInput
                isInteractive = cmd.isInteractive
            }
        }
    }

    @ViewBuilder
    private func fieldSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
