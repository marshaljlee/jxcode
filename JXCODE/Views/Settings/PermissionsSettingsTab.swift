import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Permissions Settings Tab

// MARK: - Data Model

public struct PermissionRule: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var pattern: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), pattern: String, isEnabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.isEnabled = isEnabled
    }
}

// MARK: - Rules Store

public enum PermissionRuleAction: String, Sendable {
    case allow
    case deny
}

@MainActor
@Observable
public final class PermissionRulesStore {
    public var allowRules: [PermissionRule] = []
    public var denyRules: [PermissionRule] = []

    private static var rulesFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("JXCODE").appendingPathComponent("permission_rules.json")
    }

    public init() {
        load()
    }

    public func addRule(action: PermissionRuleAction, pattern: String) {
        let rule = PermissionRule(pattern: pattern)
        switch action {
        case .allow: allowRules.append(rule)
        case .deny:  denyRules.append(rule)
        }
        save()
    }

    public func removeRule(action: PermissionRuleAction, id: UUID) {
        switch action {
        case .allow: allowRules.removeAll { $0.id == id }
        case .deny:  denyRules.removeAll { $0.id == id }
        }
        save()
    }

    public func updateRule(action: PermissionRuleAction, id: UUID, pattern: String) {
        switch action {
        case .allow:
            if let idx = allowRules.firstIndex(where: { $0.id == id }) {
                allowRules[idx].pattern = pattern
            }
        case .deny:
            if let idx = denyRules.firstIndex(where: { $0.id == id }) {
                denyRules[idx].pattern = pattern
            }
        }
        save()
    }

    public func toggleRule(action: PermissionRuleAction, id: UUID) {
        switch action {
        case .allow:
            if let idx = allowRules.firstIndex(where: { $0.id == id }) {
                allowRules[idx].isEnabled.toggle()
            }
        case .deny:
            if let idx = denyRules.firstIndex(where: { $0.id == id }) {
                denyRules[idx].isEnabled.toggle()
            }
        }
        save()
    }

    public func importAllowRules(from commands: [String]) {
        for cmd in commands where !cmd.isEmpty {
            if !allowRules.contains(where: { $0.pattern == cmd }) {
                allowRules.append(PermissionRule(pattern: cmd))
            }
        }
        save()
    }

    // MARK: - Persistence

    private struct PersistedData: Codable {
        var allowRules: [PermissionRule]
        var denyRules: [PermissionRule]
    }

    public func load() {
        let url = Self.rulesFileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            allowRules = []
            denyRules = []
            return
        }
        allowRules = decoded.allowRules
        denyRules = decoded.denyRules
    }

    public func save() {
        let url = Self.rulesFileURL
        let data = PersistedData(allowRules: allowRules, denyRules: denyRules)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: url, options: .atomic)
    }
}

// MARK: - Main Tab View

public struct PermissionsSettingsTab: View {
    @Environment(WindowState.self) private var windowState
    @State private var store = PermissionRulesStore()
    @State private var newAllowPattern: String = ""
    @State private var newDenyPattern: String = ""
    @State private var showAllowInput: Bool = false
    @State private var showDenyInput: Bool = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                allowRulesSection
                Divider()
                denyRulesSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permission Rules")
                .font(.system(size: 13, weight: .bold))
            Text("Manage command patterns that are automatically allowed or denied by the permission system. Rules are evaluated in order; the first match wins.")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Allow Rules

    private var allowRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Allow Rules",
                subtitle: "Commands matching these patterns are automatically approved without showing the permission modal.",
                count: store.allowRules.count,
                accentColor: ClaudeTheme.statusSuccess
            )

            if store.allowRules.isEmpty {
                emptyState(message: "No allow rules configured.")
                    .padding(.top, 4)
            }

            ForEach(store.allowRules) { rule in
                ruleRow(rule: rule, action: .allow)
            }

            if showAllowInput {
                addRuleInput(action: .allow, text: $newAllowPattern, isShowing: $showAllowInput)
            }

            addButton(
                label: "Add Allow Rule",
                action: { showAllowInput = true }
            )
        }
    }

    // MARK: - Deny Rules

    private var denyRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Deny Rules",
                subtitle: "Commands matching these patterns are automatically rejected without showing the permission modal.",
                count: store.denyRules.count,
                accentColor: ClaudeTheme.statusError
            )

            if store.denyRules.isEmpty {
                emptyState(message: "No deny rules configured.")
                    .padding(.top, 4)
            }

            ForEach(store.denyRules) { rule in
                ruleRow(rule: rule, action: .deny)
            }

            if showDenyInput {
                addRuleInput(action: .deny, text: $newDenyPattern, isShowing: $showDenyInput)
            }

            addButton(
                label: "Add Deny Rule",
                action: { showDenyInput = true }
            )
        }
    }

    // MARK: - Rule Row

    private func ruleRow(rule: PermissionRule, action: PermissionRuleAction) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in store.toggleRule(action: action, id: rule.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)

            TextField("Command pattern", text: Binding(
                get: { rule.pattern },
                set: { store.updateRule(action: action, id: rule.id, pattern: $0) }
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

            Button {
                store.removeRule(action: action, id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
            .buttonStyle(.plain)
            .help("Remove rule")
        }
        .padding(.leading, 2)
        .opacity(rule.isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Add Rule Input

    private func addRuleInput(action: PermissionRuleAction, text: Binding<String>, isShowing: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            TextField("e.g. npm install, git push, echo hello", text: text)
                .textFieldStyle(.plain)
                .font(.custom("JetBrains Mono NL", size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                )
                .onSubmit {
                    commitAdd(action: action, text: text, isShowing: isShowing)
                }

            Button {
                commitAdd(action: action, text: text, isShowing: isShowing)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
            }
            .buttonStyle(.plain)
            .help("Confirm")
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                text.wrappedValue = ""
                isShowing.wrappedValue = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.leading, 2)
    }

    private func commitAdd(action: PermissionRuleAction, text: Binding<String>, isShowing: Binding<Bool>) {
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addRule(action: action, pattern: trimmed)
        text.wrappedValue = ""
        isShowing.wrappedValue = false
    }

    // MARK: - Reusable Components

    private func sectionHeader(title: String, subtitle: String, count: Int, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                ruleCountBadge(count: count, color: accentColor)
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ruleCountBadge(count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
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
    PermissionsSettingsTab()
        .environment(WindowState())
        .frame(width: 600, height: 500)
}
