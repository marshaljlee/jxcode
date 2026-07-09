import SwiftUI
import JXCODECore
import JXCODEChatKit

// MARK: - Paseo Diagnostics Tab

public struct PaseoDiagnosticsTab: View {
    @Environment(AppState.self) private var appState
    @State private var osVersion: String = ""
    @State private var appVersion: String = ""
    @State private var claudeVersion: String = ""
    @State private var logText: String = ""
    @State private var isTestingConnection = false
    @State private var connectionResult: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                systemInfo
                Divider()
                connectionTest
                Divider()
                logsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadSystemInfo)
    }

    private var systemInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Information")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            VStack(spacing: 6) {
                infoRow(label: "OS Version", value: osVersion)
                infoRow(label: "App Version", value: appVersion)
                infoRow(label: "Claude CLI", value: claudeVersion)
            }
            .padding(12)
            .background(ClaudeTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Test")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            HStack(spacing: 12) {
                Button(isTestingConnection ? "Testing..." : "Test Claude Connection") {
                    testConnection()
                }
                .disabled(isTestingConnection)
                .controlSize(.small)

                if let result = connectionResult {
                    HStack(spacing: 4) {
                        Image(systemName: result.contains("OK") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.contains("OK") ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError)
                        Text(result)
                            .font(.system(size: ClaudeTheme.size(11)))
                    }
                }
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Logs")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            ScrollView([.vertical]) {
                Text(logText)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 160)
            .padding(12)
            .background(ClaudeTheme.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeTheme.border, lineWidth: 1))

            Button("Export Diagnostics") {
                exportDiagnostics()
            }
            .controlSize(.small)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            Spacer()
        }
    }

    private func loadSystemInfo() {
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        claudeVersion = appState.claudeVersion ?? "Not detected"
    }

    private func testConnection() {
        isTestingConnection = true
        connectionResult = nil
        Task {
            defer { isTestingConnection = false }
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["claude", "--version"]
                let output = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                    var out = ""
                    process.standardOutput = Pipe()
                    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { fh in
                        out += String(data: fh.availableData, encoding: .utf8) ?? ""
                    }
                    process.terminationHandler = { _ in
                        c.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    try? process.run()
                }
                connectionResult = output.isEmpty ? "No Claude CLI found" : "OK (\(output))"
                logText = "\(Date()): Connection test: \(connectionResult ?? "unknown")\n" + logText
            } catch {
                connectionResult = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JXCODE-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = """
        JXCODE Diagnostics
        =================
        Generated: \(Date())

        OS: \(osVersion)
        App: \(appVersion)
        Claude CLI: \(claudeVersion)

        Logs:
        \(logText)
        """
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}
