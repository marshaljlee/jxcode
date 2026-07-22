import SwiftUI
import JXCODECore

// MARK: - Comprehensive Proxy Tab View
// JXRouter-quality dashboard integrated as jxcode's proxy settings tab.
// Uses ProxyTheme (JXFont, JXSpacing, Color.jx*) and Components (GlassCard, StatusBadge, StatCard).

struct ProxyTabView: View {
    @State private var pm = ProxyManager.shared
    @State private var detector = AppDetector.shared
    @State private var toastMessage: String?
    @State private var toastType: ToastType = .info

    enum ToastType { case info, success, error, warning }

    var body: some View {
        ScrollView {
            VStack(spacing: JXSpacing.xl) {
                ProxyTabHeader()
                ProxyStatusSection(pm: pm)
                ProxyConfigSection(pm: pm, showToast: showToast)
                ProxyEnvSection(pm: pm, showToast: showToast)
                ProxyRoutingSection(detector: detector)
                ProxyLogsSection(pm: pm)
            }
            .padding(JXSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(Color.jxBackground)
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                toastOverlay(msg, type: toastType)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage != nil)
        .onAppear {
            detector.startMonitoring(port: pm.proxyPort)
        }
    }

    private func showToast(_ message: String, type: ToastType = .info) {
        toastMessage = message
        toastType = type
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            toastMessage = nil
        }
    }

    @ViewBuilder
    private func toastOverlay(_ message: String, type: ToastType) -> some View {
        HStack(spacing: JXSpacing.sm) {
            Image(systemName: type.icon)
                .foregroundStyle(Color.jxTextPrimary)
            Text(message)
                .font(JXFont.body)
                .foregroundStyle(Color.jxTextPrimary)
        }
        .padding(.horizontal, JXSpacing.lg)
        .padding(.vertical, JXSpacing.md)
        .background(type.fillColor, in: RoundedRectangle(cornerRadius: JXRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: JXRadius.md)
                .stroke(Color.jxSurfaceBorder.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 4)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Header

private struct ProxyTabHeader: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: JXSpacing.sm) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.jxAccent)
                    Text("Proxy Router")
                        .font(JXFont.display)
                        .foregroundStyle(Color.jxTextPrimary)
                }
                Text("Manage jxproxy routing for Anthropic API connections")
                    .font(JXFont.bodySmall)
                    .foregroundStyle(Color.jxTextSecondary)
            }
            Spacer()
        }
    }
}

// MARK: - Status Section

private struct ProxyStatusSection: View {
    @Bindable var pm: ProxyManager

    var body: some View {
        GlassCard(header: "Server Status", headerIcon: "bolt.shield.fill") {
            HStack(alignment: .top, spacing: JXSpacing.xl) {
                // Left: Status + Controls
                VStack(alignment: .leading, spacing: JXSpacing.lg) {
                    StatusBadge(status: pm.runnerStatus)
                        .padding(.bottom, 4)

                    if case .running(let pid, _, let port) = pm.runnerStatus {
                        detailRow(icon: "number", label: "PID", value: "\(pid)")
                        detailRow(icon: "rectangle.connected.to.line.below", label: "Port", value: ":\(port)")
                        detailRow(icon: "bolt.horizontal", label: "Latency", value: pm.latency > 0 ? String(format: "%.0f ms", pm.latency) : "\u{2014}")
                    }
                    if pm.runnerStatus.isActive, let start = pm.stats.startTime {
                        detailRow(icon: "clock", label: "Uptime", value: uptimeFormatted(Date().timeIntervalSince(start)))
                    }
                    if case .failed(let error) = pm.runnerStatus {
                        Text(error)
                            .font(JXFont.bodySmall)
                            .foregroundStyle(Color.jxTextError)
                            .lineLimit(3)
                    }

                    HStack(spacing: JXSpacing.sm) {
                        controlButton(
                            label: pm.runnerStatus.isActive ? "Stop" : "Start",
                            icon: pm.runnerStatus.isActive ? "stop.fill" : "play.fill",
                            color: pm.runnerStatus.isActive ? Color.jxOffline : Color.jxOnline
                        ) {
                            Task {
                                if pm.runnerStatus.isActive {
                                    await pm.stopRunner()
                                } else {
                                    await pm.startRunner()
                                }
                            }
                        }

                        if pm.runnerStatus.isActive {
                            controlButton(label: "Restart", icon: "arrow.clockwise", color: Color.jxAccentSecondary) {
                                Task { await pm.restartRunner() }
                            }
                        }
                    }
                }

                // Right: Stats Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: JXSpacing.sm), count: 2), spacing: JXSpacing.sm) {
                    StatCard(title: "Port", value: ":\(pm.proxyPort)", icon: "rectangle.connected.to.line.below", color: .jxAccent)
                    StatCard(title: "Provider", value: pm.selectedProvider, icon: "globe", color: .jxAccentSecondary)
                    StatCard(title: "Requests", value: "\(pm.stats.requestsTotal)", icon: "arrow.up.arrow.down", color: .jxOnline)
                    StatCard(title: "Log Entries", value: "\(pm.logEntries.count)", icon: "list.bullet.rectangle", color: .jxTextTertiary)
                }
                .frame(maxWidth: 320)
            }
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: JXSpacing.sm) {
            Image(systemName: icon)
                .font(JXFont.jb(10))
                .foregroundStyle(Color.jxTextTertiary)
            Text(label)
                .font(JXFont.caption)
                .foregroundStyle(Color.jxTextTertiary)
            Text(value)
                .font(JXFont.monospace)
                .foregroundStyle(Color.jxTextPrimary)
        }
    }

    private func controlButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(JXFont.jb(11, weight: .semibold))
                Text(label)
                    .font(JXFont.button)
            }
            .foregroundStyle(Color.jxTextPrimary)
            .padding(.horizontal, JXSpacing.lg)
            .padding(.vertical, JXSpacing.sm)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: JXRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: JXRadius.sm)
                    .stroke(color.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func uptimeFormatted(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

// MARK: - Config Section

private struct ProxyConfigSection: View {
    @Bindable var pm: ProxyManager
    let showToast: (String, ProxyTabView.ToastType) -> Void

    @State private var editingApiKey: Bool = false

    var body: some View {
        GlassCard(header: "Router Configuration", headerIcon: "gearshape.2.fill", accentColor: .jxAccentSecondary) {
            VStack(spacing: JXSpacing.lg) {
                // Port + Provider + Model row
                HStack(spacing: JXSpacing.xl) {
                    configField("Port", value: Binding(
                        get: { String(pm.proxyPort) },
                        set: { if let p = Int($0) { pm.proxyPort = p } }
                    ), placeholder: "5255", width: 100, monospace: true)

                    VStack(alignment: .leading, spacing: JXSpacing.xs) {
                        fieldLabel("PROVIDER")
                        Picker("", selection: $pm.selectedProvider) {
                            ForEach(ProxyConfig.Provider.allCases) { p in
                                Text(p.rawValue).tag(p.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    configField("Model", text: $pm.selectedModel, placeholder: "model", width: 220)
                }

                // API Key + Fallback providers row
                HStack(spacing: JXSpacing.xl) {
                    VStack(alignment: .leading, spacing: JXSpacing.xs) {
                        fieldLabel("API KEY")
                        HStack(spacing: 6) {
                            if pm.apiKey.isEmpty || !editingApiKey {
                                Text(pm.apiKey.isEmpty ? "Not set" : "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                                    .font(JXFont.monospace)
                                    .foregroundStyle(pm.apiKey.isEmpty ? Color.jxTextTertiary : Color.jxTextSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                    .onTapGesture { editingApiKey = true }
                                if !pm.apiKey.isEmpty && !editingApiKey {
                                    Button { editingApiKey = true } label: {
                                        Image(systemName: "pencil")
                                            .font(JXFont.jb(9))
                                            .foregroundStyle(Color.jxTextTertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                TextField("sk-...", text: $pm.apiKey)
                                    .textFieldStyle(.plain)
                                    .font(JXFont.monospace)
                                    .foregroundStyle(Color.jxTextPrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.jxBackground, in: RoundedRectangle(cornerRadius: JXRadius.sm))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: JXRadius.sm)
                                            .stroke(Color.jxAccent.opacity(0.5), lineWidth: 0.5)
                                    )
                                    .onSubmit { editingApiKey = false }
                                Button { editingApiKey = false } label: {
                                    Image(systemName: "checkmark").font(JXFont.jb(9, weight: .bold)).foregroundStyle(Color.jxTextSuccess)
                                }.buttonStyle(.plain)
                                Button { editingApiKey = false } label: {
                                    Image(systemName: "xmark").font(JXFont.jb(9)).foregroundStyle(Color.jxTextTertiary)
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, JXSpacing.sm)
                        .padding(.vertical, 6)
                        .background(Color.jxBackgroundSecondary, in: RoundedRectangle(cornerRadius: JXRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: JXRadius.sm)
                                .stroke(Color.jxSurfaceBorder.opacity(0.4), lineWidth: 0.5)
                        )
                        .frame(width: 240)
                    }

                    VStack(alignment: .leading, spacing: JXSpacing.xs) {
                        fieldLabel("FALLBACK PROVIDERS")
                        HStack(spacing: JXSpacing.sm) {
                            ForEach(["openrouter", "opencode-go", "openai", "local"], id: \.self) { name in
                                let isSelected = pm.fallbackProviders.contains(name)
                                Button {
                                    if isSelected {
                                        pm.fallbackProviders.removeAll { $0 == name }
                                    } else {
                                        pm.fallbackProviders.append(name)
                                    }
                                } label: {
                                    Text(name)
                                        .font(JXFont.jb(9, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(isSelected ? Color.jxAccentDim : Color.jxBackgroundTertiary)
                                        .foregroundColor(isSelected ? Color.jxTextAccent : Color.jxTextSecondary)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Options row
                Divider().overlay(Color.jxSurfaceBorder.opacity(0.3))

                VStack(spacing: JXSpacing.md) {
                    HStack(spacing: JXSpacing.xl) {
                        Toggle(isOn: $pm.launchAtLogin) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Launch at login")
                                    .font(JXFont.body)
                                    .foregroundStyle(Color.jxTextPrimary)
                                Text("Open JXCODE automatically at login")
                                    .font(JXFont.caption)
                                    .foregroundStyle(Color.jxTextTertiary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Toggle(isOn: $pm.proxyAllTraffic) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Route all API traffic")
                                    .font(JXFont.body)
                                    .foregroundStyle(Color.jxTextPrimary)
                                Text("All detected Anthropic traffic routed through proxy")
                                    .font(JXFont.caption)
                                    .foregroundStyle(Color.jxTextTertiary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    HStack(spacing: JXSpacing.xl) {
                        VStack(alignment: .leading, spacing: JXSpacing.xs) {
                            fieldLabel("LOG LEVEL")
                            Picker("", selection: $pm.logLevel) {
                                Text("Debug").tag("debug")
                                Text("Info").tag("info")
                                Text("Warn").tag("warn")
                                Text("Error").tag("error")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                        }

                        VStack(alignment: .leading, spacing: JXSpacing.xs) {
                            fieldLabel("TIMEOUT")
                            Picker("", selection: $pm.requestTimeoutSeconds) {
                                Text("15s").tag(15)
                                Text("30s").tag(30)
                                Text("60s").tag(60)
                                Text("120s").tag(120)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                        }
                    }
                }

                // Save button
                HStack {
                    Spacer()
                    Button(action: { pm.saveConfig(); showToast("Configuration saved", .success) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").font(JXFont.jb(11))
                            Text("Save Configuration").font(JXFont.button)
                        }
                        .foregroundStyle(Color.jxTextPrimary)
                        .padding(.horizontal, JXSpacing.lg)
                        .padding(.vertical, JXSpacing.sm)
                        .background(Color.jxAccentSecondary.opacity(0.15), in: RoundedRectangle(cornerRadius: JXRadius.sm))
                        .overlay(RoundedRectangle(cornerRadius: JXRadius.sm).stroke(Color.jxAccentSecondary.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func configField(_ label: String, value: Binding<String>, placeholder: String, width: CGFloat, monospace: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: JXSpacing.xs) {
            fieldLabel(label)
            TextField(placeholder, text: value)
                .textFieldStyle(.plain)
                .font(monospace ? JXFont.monospace : JXFont.body)
                .foregroundStyle(Color.jxTextPrimary)
                .padding(.horizontal, JXSpacing.sm)
                .padding(.vertical, 6)
                .background(Color.jxBackgroundSecondary, in: RoundedRectangle(cornerRadius: JXRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: JXRadius.sm).stroke(Color.jxSurfaceBorder.opacity(0.4), lineWidth: 0.5))
                .frame(width: width)
        }
    }

    private func configField(_ label: String, text: Binding<String>, placeholder: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: JXSpacing.xs) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(JXFont.monospace)
                .foregroundStyle(Color.jxTextPrimary)
                .padding(.horizontal, JXSpacing.sm)
                .padding(.vertical, 6)
                .background(Color.jxBackgroundSecondary, in: RoundedRectangle(cornerRadius: JXRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: JXRadius.sm).stroke(Color.jxSurfaceBorder.opacity(0.4), lineWidth: 0.5))
                .frame(width: width)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(JXFont.label)
            .foregroundStyle(Color.jxTextSecondary)
    }
}

// MARK: - Env Section (editable, from JXRouter)

private struct ProxyEnvSection: View {
    @Bindable var pm: ProxyManager
    let showToast: (String, ProxyTabView.ToastType) -> Void

    @State private var editingKey: String?
    @State private var editValue: String = ""
    @State private var envVars: [(key: String, value: String, source: String, sensitive: Bool)] = []

    private let keyColumn: CGFloat = 220
    private let sourceColumn: CGFloat = 100

    var body: some View {
        GlassCard(header: "Environment Variables", headerIcon: "doc.text.magnifyingglass", accentColor: .jxAccentSecondary) {
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: JXSpacing.md) {
                    Text("VARIABLE")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(width: keyColumn, alignment: .leading)
                    Text("VALUE")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("SOURCE")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(width: sourceColumn, alignment: .leading)
                }
                .padding(.horizontal, JXSpacing.sm)
                .padding(.vertical, JXSpacing.sm)

                Divider().overlay(Color.jxSurfaceBorder.opacity(0.3))

                if envVars.isEmpty {
                    VStack(spacing: JXSpacing.md) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.jxTextTertiary)
                        Text("No environment variables loaded")
                            .font(JXFont.body)
                            .foregroundStyle(Color.jxTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, JXSpacing.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(envVars.enumerated()), id: \.offset) { idx, v in
                                envVarRow(v, index: idx)
                                if idx < envVars.count - 1 {
                                    Divider().overlay(Color.jxSurfaceBorder.opacity(0.15))
                                }
                            }
                        }
                        .padding(.vertical, JXSpacing.xs)
                    }
                    .frame(minHeight: 120, maxHeight: 300)
                }

                // Sensitive notice
                HStack(spacing: JXSpacing.sm) {
                    Image(systemName: "lock.shield.fill")
                        .font(JXFont.jb(12))
                        .foregroundStyle(Color.jxWarning)
                    Text("Sensitive values (API keys) are masked by default. Click to edit.")
                        .font(JXFont.caption)
                        .foregroundStyle(Color.jxTextTertiary)
                }
                .padding(JXSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.jxBackgroundTertiary, in: RoundedRectangle(cornerRadius: JXRadius.md))
            }
        }
        .onAppear { reloadEnv() }
        .onChange(of: pm.proxyPort) { _, _ in reloadEnv() }
    }

    private func reloadEnv() {
        envVars = pm.loadEnvVars()
    }

    @ViewBuilder
    private func envVarRow(_ variable: (key: String, value: String, source: String, sensitive: Bool), index: Int) -> some View {
        let isEditing = editingKey == variable.key
        HStack(spacing: JXSpacing.md) {
            // Key
            Text(variable.key)
                .font(JXFont.monospaceSmall)
                .foregroundStyle(variable.sensitive ? Color.jxTextWarning : Color.jxTextPrimary)
                .frame(width: keyColumn, alignment: .leading)
                .lineLimit(1)

            // Value (editable)
            Group {
                if variable.sensitive && !isEditing {
                    HStack(spacing: 6) {
                        Text(variable.value.isEmpty ? "Not set" : "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                            .font(JXFont.monospaceSmall)
                            .foregroundStyle(variable.value.isEmpty ? Color.jxTextTertiary : Color.jxTextSecondary)
                        if !variable.value.isEmpty {
                            Image(systemName: "lock.fill")
                                .font(JXFont.jb(7))
                                .foregroundStyle(Color.jxTextTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { beginEditing(variable) }
                } else if isEditing {
                    HStack(spacing: 6) {
                        TextField("Value", text: $editValue)
                            .textFieldStyle(.plain)
                            .font(JXFont.monospaceSmall)
                            .foregroundStyle(Color.jxTextPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.jxBackground, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.jxAccent.opacity(0.5), lineWidth: 0.5))
                            .onSubmit { commitEditing(key: variable.key) }

                        Button { commitEditing(key: variable.key) } label: {
                            Image(systemName: "checkmark")
                                .font(JXFont.jb(9, weight: .bold))
                                .foregroundStyle(Color.jxTextSuccess)
                        }.buttonStyle(.plain)

                        Button { cancelEditing() } label: {
                            Image(systemName: "xmark")
                                .font(JXFont.jb(9))
                                .foregroundStyle(Color.jxTextTertiary)
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(variable.value.isEmpty ? "Not set" : variable.value)
                        .font(JXFont.monospaceSmall)
                        .foregroundStyle(variable.value.isEmpty ? Color.jxTextTertiary : Color.jxTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .contentShape(.rect)
                        .onTapGesture { beginEditing(variable) }
                }
            }

            // Source badge
            HStack(spacing: 4) {
                Circle()
                    .fill(sourceColor(variable.source))
                    .frame(width: 5, height: 5)
                Text(variable.source)
                    .font(JXFont.caption)
                    .foregroundStyle(Color.jxTextTertiary)
            }
            .frame(width: sourceColumn, alignment: .leading)
        }
        .padding(.horizontal, JXSpacing.sm)
        .padding(.vertical, JXSpacing.sm)
    }

    private func beginEditing(_ variable: (key: String, value: String, source: String, sensitive: Bool)) {
        editingKey = variable.key
        editValue = variable.value
    }

    private func commitEditing(key: String) {
        pm.updateEnvVar(key: key, value: editValue)
        editingKey = nil
        editValue = ""
        reloadEnv()
        showToast("\(key) updated", .success)
    }

    private func cancelEditing() {
        editingKey = nil
        editValue = ""
    }

    private func sourceColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "system": return Color.jxOnline
        case "config", "proxy config": return Color.jxAccent
        case "user set", "user": return Color.jxWarning
        default: return Color.jxTextTertiary
        }
    }
}

// MARK: - Routing Section

private struct ProxyRoutingSection: View {
    @Bindable var detector: AppDetector

    private let nameColumn: CGFloat = 180
    private let statusColumn: CGFloat = 70

    var body: some View {
        GlassCard(header: "Detected Routing Apps", headerIcon: "arrow.triangle.branch", accentColor: .jxOnline) {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: JXSpacing.md) {
                    Text("APPLICATION")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(width: nameColumn, alignment: .leading)
                    Text("STATUS")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(width: statusColumn, alignment: .leading)
                    Text("ROUTE")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("CONNS")
                        .font(JXFont.label)
                        .foregroundStyle(Color.jxTextTertiary)
                        .frame(width: 55, alignment: .trailing)
                }
                .padding(.horizontal, JXSpacing.sm)
                .padding(.vertical, JXSpacing.sm)

                Divider().overlay(Color.jxSurfaceBorder.opacity(0.3))

                if detector.detectedApps.isEmpty {
                    VStack(spacing: JXSpacing.md) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.jxTextTertiary)
                        Text("No apps detected yet")
                            .font(JXFont.body)
                            .foregroundStyle(Color.jxTextSecondary)
                        Text("Apps making Anthropic API connections will appear here automatically")
                            .font(JXFont.caption)
                            .foregroundStyle(Color.jxTextTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, JXSpacing.xxl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(detector.detectedApps) { app in
                                appRow(app)
                                if app.id != detector.detectedApps.last?.id {
                                    Divider().overlay(Color.jxSurfaceBorder.opacity(0.15))
                                }
                            }
                        }
                        .padding(.vertical, JXSpacing.xs)
                    }
                    .frame(minHeight: 100, maxHeight: 250)
                }
            }
        }
    }

    @ViewBuilder
    private func appRow(_ app: RoutingApp) -> some View {
        HStack(spacing: JXSpacing.md) {
            // App icon + name
            HStack(spacing: JXSpacing.sm) {
                Image(systemName: app.icon)
                    .font(JXFont.jb(12))
                    .foregroundStyle(Color.jxAccent)
                    .frame(width: 22, height: 22)
                    .background(Color.jxAccentDim, in: RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(JXFont.body)
                        .foregroundStyle(Color.jxTextPrimary)
                        .lineLimit(1)
                    Text(app.bundleIdentifier)
                        .font(JXFont.caption)
                        .foregroundStyle(Color.jxTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: nameColumn, alignment: .leading)

            // Status badge
            RoutingStatusBadge(status: app.status)
                .frame(width: statusColumn, alignment: .leading)

            // Route picker
            HStack(spacing: 4) {
                Image(systemName: routeIcon(app.routeAssignment))
                    .font(JXFont.jb(9))
                    .foregroundStyle(routeColor(app.routeAssignment))
                Picker("", selection: Binding(
                    get: { app.routeAssignment },
                    set: { detector.setRoute(appId: app.id, assignment: $0) }
                )) {
                    ForEach(RoutingApp.RouteAssignment.allCases) { route in
                        Text(route.rawValue).tag(route)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(JXFont.caption)
                .frame(width: 80)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Connection count
            Text("\(app.connectionCount)")
                .font(JXFont.monospace)
                .foregroundStyle(Color.jxTextSecondary)
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.horizontal, JXSpacing.sm)
        .padding(.vertical, JXSpacing.sm)
        .contextMenu {
            ForEach(RoutingApp.RouteAssignment.allCases) { route in
                Button {
                    detector.setRoute(appId: app.id, assignment: route)
                } label: {
                    Label(route.rawValue, systemImage: routeIcon(route))
                }
            }
            Divider()
            Button(role: .destructive) {
                detector.ignoreApp(appId: app.id)
            } label: {
                Label("Ignore", systemImage: "eye.slash")
            }
        }
    }

    private func routeIcon(_ route: RoutingApp.RouteAssignment) -> String {
        switch route {
        case .auto: return "wand.and.stars"
        case .direct: return "antenna.radiowaves.left.and.right"
        case .openrouter: return "arrow.triangle.swap"
        case .opencode: return "sparkle"
        case .openai: return "brain"
        case .local: return "desktopcomputer"
        case .block: return "hand.raised.fill"
        }
    }

    private func routeColor(_ route: RoutingApp.RouteAssignment) -> Color {
        switch route {
        case .block: return Color.jxOffline
        case .auto: return Color.jxWarning
        default: return Color.jxAccent
        }
    }
}

// MARK: - Logs Section

private struct ProxyLogsSection: View {
    @Bindable var pm: ProxyManager
    @State private var filterLevel: ProxyConfig.LogLevel?

    private var filteredLogs: [ProxyLogEntry] {
        guard let level = filterLevel else { return pm.logEntries }
        return pm.logEntries.filter { $0.level == level }
    }

    var body: some View {
        GlassCard(header: "Proxy Logs", headerIcon: "list.bullet.rectangle.fill", accentColor: .jxTextTertiary) {
            VStack(spacing: JXSpacing.md) {
                // Filter bar
                HStack {
                    HStack(spacing: JXSpacing.xs) {
                        ForEach(ProxyConfig.LogLevel.allCases) { level in
                            Button {
                                filterLevel = filterLevel == level ? nil : level
                            } label: {
                                Text(level.rawValue.uppercased())
                                    .font(JXFont.caption)
                                    .foregroundStyle(filterLevel == level ? Color.jxTextPrimary : Color.jxTextTertiary)
                                    .padding(.horizontal, JXSpacing.sm)
                                    .padding(.vertical, 3)
                                    .background(filterLevel == level ? logColor(level).opacity(0.2) : Color.jxBackgroundTertiary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Button(action: { pm.clearLogs() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(JXFont.jb(9))
                            Text("Clear").font(JXFont.caption)
                        }
                        .foregroundStyle(Color.jxTextTertiary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Color.jxSurfaceBorder.opacity(0.3))

                if filteredLogs.isEmpty {
                    VStack(spacing: JXSpacing.sm) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.jxTextTertiary)
                        Text("No log entries")
                            .font(JXFont.body)
                            .foregroundStyle(Color.jxTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, JXSpacing.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredLogs) { entry in
                                logRow(entry)
                                if entry.id != filteredLogs.last?.id {
                                    Divider().overlay(Color.jxSurfaceBorder.opacity(0.1))
                                }
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                }
            }
        }
    }

    private func logRow(_ entry: ProxyLogEntry) -> some View {
        HStack(spacing: JXSpacing.sm) {
            Text(entry.timestamp, style: .time)
                .font(JXFont.monospaceSmall)
                .foregroundStyle(Color.jxTextTertiary)
                .frame(width: 55, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(JXFont.caption)
                .foregroundStyle(logColor(entry.level))
                .frame(width: 42, alignment: .leading)

            Text(entry.source)
                .font(JXFont.caption)
                .foregroundStyle(Color.jxTextTertiary)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(JXFont.monospaceSmall)
                .foregroundStyle(Color.jxTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, JXSpacing.sm)
        .padding(.vertical, 5)
    }

    private func logColor(_ level: ProxyConfig.LogLevel) -> Color {
        switch level {
        case .debug: return Color.jxTextTertiary
        case .info: return Color.jxTextAccent
        case .warn: return Color.jxTextWarning
        case .error: return Color.jxTextError
        }
    }
}

// MARK: - ToastType UI helpers

private extension ProxyTabView.ToastType {
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var fillColor: Color {
        switch self {
        case .success: return Color.jxOnline.opacity(0.9)
        case .error: return Color.jxOffline.opacity(0.9)
        case .warning: return Color.jxWarning.opacity(0.9)
        case .info: return Color.jxAccentSecondary.opacity(0.9)
        }
    }
}
