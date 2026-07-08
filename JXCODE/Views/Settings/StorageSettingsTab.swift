import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Storage Settings Tab

public struct StorageSettingsTab: View {
    @State private var storageInfo: [(String, UInt64)] = []
    @State private var isCalculating = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                storageBreakdown
                Divider()
                actions
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: calculateStorage)
    }

    private var storageBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Usage")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            if isCalculating {
                HStack { ProgressView().controlSize(.small); Text("Calculating...").font(.system(size: ClaudeTheme.size(11))).foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 8) {
                    ForEach(storageInfo, id: \.0) { (label, size) in
                        HStack {
                            Text(label)
                                .font(.system(size: ClaudeTheme.size(12)))
                            Spacer()
                            Text(formatBytes(size))
                                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Text("Total")
                            .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        Spacer()
                        Text(formatBytes(storageInfo.reduce(0) { $0 + $1.1 }))
                            .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    }
                }
                .padding(12)
                .background(ClaudeTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 8) {
                Button(action: exportSettings) {
                    Label("Export Settings", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(ClaudeTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: clearCache) {
                    Label("Clear Cache", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(ClaudeTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func calculateStorage() {
        storageInfo = []
        let fm = FileManager.default
        let paths: [(String, FileManager.SearchPathDirectory)] = [
            ("Session Data", .applicationSupportDirectory),
            ("Caches", .cachesDirectory),
        ]
        for (label, dir) in paths {
            if let url = fm.urls(for: dir, in: .userDomainMask).first {
                let size = directorySize(url)
                storageInfo.append((label, size))
            }
        }
        isCalculating = false
    }

    private func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        return total
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JXCODE-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let jxcodeSettings = defaults.filter { $0.key.hasPrefix("jxcode.") || $0.key.hasPrefix("JXCODE.") }
        if let data = try? JSONSerialization.data(withJSONObject: jxcodeSettings, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }

    private func clearCache() {
        let alert = NSAlert()
        alert.messageText = "Clear Cache?"
        alert.informativeText = "This will remove cached data. Session files will not be affected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateStorage()
    }

    private func updateStorage() {
        Task { await MainActor.run { calculateStorage() } }
    }
}
