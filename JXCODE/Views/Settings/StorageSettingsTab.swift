import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Storage Settings Tab

public struct StorageSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var storageCategories: [StorageCategory] = []
    @State private var totalSize: UInt64 = 0
    @State private var isCalculating = true
    @State private var showClearCacheConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isClearing = false
    @State private var clearResult: String?
    @State private var importResult: String?

    public init() {}

    // MARK: - Storage Category Model

    private struct StorageCategory: Identifiable {
        let id: String
        let label: String
        let icon: String
        let path: URL
        var size: UInt64
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                storageBreakdownSection
                Divider()
                actionsSection
                Divider()
                importExportSection
                Divider()
                resetSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: calculateAllStorageSizes)
        .alert("Clear Cache", isPresented: $showClearCacheConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clearCache() }
        } message: {
            Text("This will remove cached data. Session files, logs, and settings will not be affected. This action cannot be undone.")
        }
        .alert("Reset All Settings", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { resetAllSettings() }
        } message: {
            Text("All application settings will be restored to their defaults. Session data, projects, and cached files will not be removed. This action cannot be undone.")
        }
    }

    // MARK: - Storage Breakdown

    private var storageBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Usage")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Text("Data stored by JXCODE on disk, broken down by category.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            if isCalculating {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Calculating storage sizes...")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ClaudeTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            } else {
                VStack(spacing: 0) {
                    ForEach(storageCategories) { category in
                        categoryRow(category: category)
                        if category.id != storageCategories.last?.id {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                    Divider()
                    totalRow
                }
                .background(ClaudeTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                )

                Text("Storage usage is calculated from files in the application support and cache directories.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
    }

    private func categoryRow(category: StorageCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.label)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                Text(category.path.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(formatBytes(category.size))
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var totalRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 20, alignment: .center)

            Text("Total")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))

            Spacer()

            Text(formatBytes(totalSize))
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Actions")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 8) {
                clearCacheButton
                recalculateButton
            }
        }
    }

    private var clearCacheButton: some View {
        Button(action: { showClearCacheConfirmation = true }) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clear Cache")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    Text("Remove temporary cached data to free up disk space.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isClearing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .disabled(isClearing)

        if let result = clearResult {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                    .font(.system(size: ClaudeTheme.size(11)))
                Text(result)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var recalculateButton: some View {
        Button(action: calculateAllStorageSizes) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recalculate")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    Text("Re-scan all storage directories to update usage figures.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import / Export

    private var importExportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import / Export")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 8) {
                exportSettingsButton
                importSettingsButton
            }

            if let result = importResult {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                        .font(.system(size: ClaudeTheme.size(11)))
                    Text(result)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var exportSettingsButton: some View {
        Button(action: exportSettings) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Settings")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    Text("Save all JXCODE preferences to a JSON file for backup or transfer.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
    }

    private var importSettingsButton: some View {
        Button(action: importSettings) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Settings")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    Text("Restore preferences from a previously exported settings file.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reset

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 8) {
                Button(action: { showResetConfirmation = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "gear.badge.xmark")
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.statusError)
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset All Settings")
                                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                            Text("Restore all preferences to their factory defaults. Projects and session data are preserved.")
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(ClaudeTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .strokeBorder(ClaudeTheme.statusError.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Storage Calculation

    private func calculateAllStorageSizes() {
        isCalculating = true
        clearResult = nil
        importResult = nil

        let fm = FileManager.default
        let supportURL = AppSupport.bundleScopedURL
        let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "com.idealapp.JXCODE"
        let appCachesURL = cachesURL.appendingPathComponent(bundleID, isDirectory: true)

        let categories = [
            StorageCategory(
                id: "session-data",
                label: "Session Data",
                icon: "message",
                path: supportURL.appendingPathComponent("sessions", isDirectory: true),
                size: 0
            ),
            StorageCategory(
                id: "cli-sessions",
                label: "CLI Session Cache",
                icon: "terminal",
                path: supportURL.appendingPathComponent("session-meta", isDirectory: true),
                size: 0
            ),
            StorageCategory(
                id: "agent-runs",
                label: "Agent Run Logs",
                icon: "gearshape.2",
                path: supportURL.appendingPathComponent("agent_runs", isDirectory: true),
                size: 0
            ),
            StorageCategory(
                id: "usage-records",
                label: "Usage Analytics",
                icon: "chart.bar",
                path: supportURL.appendingPathComponent("usage_records.json"),
                size: 0
            ),
            StorageCategory(
                id: "app-support",
                label: "App Support (Projects, GitHub Cache)",
                icon: "folder",
                path: supportURL,
                size: 0
            ),
            StorageCategory(
                id: "caches",
                label: "App Cache",
                icon: "archivebox",
                path: appCachesURL,
                size: 0
            ),
        ]

        // Calculate sizes concurrently on a background queue
        DispatchQueue.global(qos: .utility).async {
            let computed = categories.map { cat in
                var mutable = cat
                mutable.size = directorySize(cat.path)
                return mutable
            }
            let total = computed.reduce(0) { $0 + $1.size }

            DispatchQueue.main.async {
                storageCategories = computed
                totalSize = total
                isCalculating = false
            }
        }
    }

    private func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if isDir.boolValue {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return 0 }

            var total: UInt64 = 0
            for case let fileURL as URL in enumerator {
                let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if resourceValues?.isRegularFile == true, let size = resourceValues?.fileSize {
                    total += UInt64(size)
                }
            }
            return total
        } else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? UInt64) ?? 0
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.formattingContext = .standalone
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Clear Cache

    private func clearCache() {
        isClearing = true
        clearResult = nil

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let bundleID = Bundle.main.bundleIdentifier ?? "com.idealapp.JXCODE"
            let appCachesURL = cachesURL.appendingPathComponent(bundleID, isDirectory: true)

            var removedCount = 0

            if fm.fileExists(atPath: appCachesURL.path) {
                // Remove all contents but keep the directory itself
                if let contents = try? fm.contentsOfDirectory(
                    at: appCachesURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for url in contents {
                        try? fm.removeItem(at: url)
                        removedCount += 1
                    }
                }
            }

            DispatchQueue.main.async {
                isClearing = false
                clearResult = "Cache cleared. Removed \(removedCount) item(s)."
                calculateAllStorageSizes()

                // Auto-dismiss the result after 4 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation {
                        clearResult = nil
                    }
                }
            }
        }
    }

    // MARK: - Export Settings

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export JXCODE Settings"
        panel.nameFieldStringValue = "JXCODE-settings.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let jxcodeSettings = defaults.filter { $0.key.hasPrefix("jxcode.") || $0.key.hasPrefix("JXCODE.") }

        let export: [String: Any] = [
            "app": "JXCODE",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": jxcodeSettings
        ]

        if let data = try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = "Could not write settings to the selected location: \(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - Import Settings

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import JXCODE Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                showImportError("The selected file does not contain valid JSON.")
                return
            }

            guard (json["app"] as? String) == "JXCODE" else {
                showImportError("The selected file is not a valid JXCODE settings export.")
                return
            }

            guard let settings = json["settings"] as? [String: Any] else {
                showImportError("The settings file is missing the settings data.")
                return
            }

            let defaults = UserDefaults.standard
            for (key, value) in settings {
                defaults.set(value, forKey: key)
            }

            withAnimation {
                importResult = "Settings imported successfully from \(url.lastPathComponent). Some changes may require an app restart."
            }

            // Auto-dismiss after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation {
                    importResult = nil
                }
            }

        } catch {
            showImportError("Failed to read the settings file: \(error.localizedDescription)")
        }
    }

    private func showImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Reset All Settings

    private func resetAllSettings() {
        let defaults = UserDefaults.standard
        let jxcodeKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("jxcode.") || $0.hasPrefix("JXCODE.")
        }
        for key in jxcodeKeys {
            defaults.removeObject(forKey: key)
        }

        withAnimation {
            importResult = "All settings reset to defaults. An app restart is recommended for changes to take full effect."
        }

        // Auto-dismiss after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation {
                importResult = nil
            }
        }
    }
}
