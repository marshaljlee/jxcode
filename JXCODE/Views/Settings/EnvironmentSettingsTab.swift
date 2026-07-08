import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Environment Settings Tab

// MARK: - Data Model

public struct EnvironmentVariable: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var key: String
    public var value: String
    public var isSecret: Bool
    public var isEnabled: Bool

    public init(id: UUID = UUID(), key: String, value: String = "", isSecret: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.key = key
        self.value = value
        self.isSecret = isSecret
        self.isEnabled = isEnabled
    }
}

// MARK: - Store

@MainActor
@Observable
public final class EnvironmentVariablesStore {
    public var variables: [EnvironmentVariable] = []

    private static var storeFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("JXCODE").appendingPathComponent("environment_variables.json")
    }

    public init() {
        load()
    }

    public func add(key: String, value: String, isSecret: Bool = false) {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        let variable = EnvironmentVariable(key: trimmedKey, value: value, isSecret: isSecret)
        variables.append(variable)
        save()
    }

    public func remove(id: UUID) {
        variables.removeAll { $0.id == id }
        save()
    }

    public func update(id: UUID, key: String, value: String) {
        guard let idx = variables.firstIndex(where: { $0.id == id }) else { return }
        variables[idx].key = key
        variables[idx].value = value
        save()
    }

    public func toggleSecret(id: UUID) {
        guard let idx = variables.firstIndex(where: { $0.id == id }) else { return }
        variables[idx].isSecret.toggle()
        save()
    }

    public func toggleEnabled(id: UUID) {
        guard let idx = variables.firstIndex(where: { $0.id == id }) else { return }
        variables[idx].isEnabled.toggle()
        save()
    }

    /// Returns the active (enabled) environment variables as a dictionary for injection into subprocess environments.
    public func activeEnvironment() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: variables
                .filter { $0.isEnabled && !$0.key.isEmpty }
                .map { ($0.key, $0.value) }
        )
    }

    // MARK: - Persistence

    public func load() {
        let url = Self.storeFileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([EnvironmentVariable].self, from: data) else {
            variables = []
            return
        }
        variables = decoded
    }

    public func save() {
        let url = Self.storeFileURL
        guard let encoded = try? JSONEncoder().encode(variables) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: url, options: .atomic)
    }
}

// MARK: - Main Tab View

public struct EnvironmentSettingsTab: View {
    @State private var store = EnvironmentVariablesStore()
    @State private var newKey: String = ""
    @State private var newValue: String = ""
    @State private var newIsSecret: Bool = false
    @State private var showAddRow: Bool = false
    @State private var editingSecretId: UUID?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                variablesSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Environment Variables")
                .font(.system(size: 13, weight: .bold))
            Text("Define custom environment variables that are injected into Claude CLI subprocesses. Secret values are masked by default and never displayed in plain text.")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Variables Section

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Variables",
                subtitle: "Active variables are merged into the environment of every spawned Claude process.",
                count: store.variables.count
            )

            if store.variables.isEmpty {
                emptyState(message: "No environment variables configured.")
                    .padding(.top, 4)
            }

            ForEach(store.variables) { variable in
                variableRow(variable: variable)
            }

            if showAddRow {
                addVariableRow
            }

            addButton(
                label: "Add Variable",
                action: { showAddRow = true }
            )
        }
    }

    // MARK: - Variable Row

    private func variableRow(variable: EnvironmentVariable) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { variable.isEnabled },
                set: { _ in store.toggleEnabled(id: variable.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)

            TextField("KEY", text: Binding(
                get: { variable.key },
                set: { store.update(id: variable.id, key: $0, value: variable.value) }
            ))
            .textFieldStyle(.plain)
            .font(.custom("JetBrains Mono NL", size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
            )
            .frame(width: 200, alignment: .leading)

            HStack(spacing: 4) {
                if variable.isSecret {
                    if editingSecretId == variable.id {
                        TextField("value", text: Binding(
                            get: { variable.value },
                            set: { store.update(id: variable.id, key: variable.key, value: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.custom("JetBrains Mono NL", size: 11))
                    } else {
                        Text(String(repeating: "•", count: min(variable.value.count, 20)))
                            .font(.custom("JetBrains Mono NL", size: 11))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                    }
                } else {
                    TextField("value", text: Binding(
                        get: { variable.value },
                        set: { store.update(id: variable.id, key: variable.key, value: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrains Mono NL", size: 11))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ClaudeTheme.border, lineWidth: 1)
            )

            Button {
                store.toggleSecret(id: variable.id)
                if variable.isSecret {
                    editingSecretId = variable.id
                } else {
                    editingSecretId = nil
                }
            } label: {
                Image(systemName: variable.isSecret ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(variable.isSecret ? "Show value" : "Hide value")

            Button {
                store.remove(id: variable.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
            .buttonStyle(.plain)
            .help("Remove variable")
        }
        .padding(.leading, 2)
        .opacity(variable.isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Add Variable Row

    private var addVariableRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("KEY", text: $newKey)
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrains Mono NL", size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                    )
                    .frame(width: 200, alignment: .leading)

                TextField("value", text: $newValue)
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrains Mono NL", size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                    )

                Button {
                    newIsSecret.toggle()
                } label: {
                    Image(systemName: newIsSecret ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(newIsSecret ? "Mark as secret" : "Mark as plain text")

                Button {
                    commitAdd()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                }
                .buttonStyle(.plain)
                .help("Confirm")
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    cancelAdd()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text(newIsSecret ? "Value will be masked in the list." : "Value will be visible in the list.")
                    .font(.system(size: 9))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
        }
    }

    private func commitAdd() {
        let trimmedKey = newKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        store.add(key: trimmedKey, value: newValue, isSecret: newIsSecret)
        newKey = ""
        newValue = ""
        newIsSecret = false
        showAddRow = false
    }

    private func cancelAdd() {
        newKey = ""
        newValue = ""
        newIsSecret = false
        showAddRow = false
    }

    // MARK: - Reusable Components

    private func sectionHeader(title: String, subtitle: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                countBadge(count: count)
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countBadge(count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ClaudeTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ClaudeTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func emptyState(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    private func addButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(ClaudeTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ClaudeTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    EnvironmentSettingsTab()
        .frame(width: 600, height: 500)
}
