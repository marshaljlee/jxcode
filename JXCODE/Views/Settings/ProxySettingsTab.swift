import SwiftUI
import JXCODECore

struct ProxySettingsTab: View {
    @State private var proxyManager = ProxyManager.shared
    @State private var subTab: Int = 0
    
    let providers = [
        "OpenCode Zen / Big-Pickle",
        "Nvidia NIM",
        "Nemotron 3 Ultra",
        "Ollama Qwen"
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("", selection: $subTab) {
                Text("Config").tag(0)
                Text("Free Runner").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            
            Divider()
            
            if subTab == 0 {
                configPane
            } else {
                runnerPane
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    // MARK: - Tab 1: Config Pane
    private var configPane: some View {
        @Bindable var pm = proxyManager
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("System Proxies")
                        .font(.system(size: 13, weight: .bold))
                    Text("Configure custom network proxies for outbound requests.")
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                
                Toggle("Enable System Proxy Routing", isOn: $pm.isProxyEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: pm.isProxyEnabled) { _, _ in pm.saveConfig() }
                
                VStack(spacing: 12) {
                    labeledTextField(label: "HTTP Proxy", text: $pm.httpProxy, placeholder: "http://127.0.0.1:8080")
                    labeledTextField(label: "HTTPS Proxy", text: $pm.httpsProxy, placeholder: "http://127.0.0.1:8080")
                    labeledTextField(label: "No Proxy", text: $pm.noProxy, placeholder: "localhost,127.0.0.1,.example.com")
                    labeledTextField(label: "All Proxy (SOCKS)", text: $pm.allProxy, placeholder: "socks5://127.0.0.1:1080")
                }
                .disabled(!pm.isProxyEnabled)
                .opacity(pm.isProxyEnabled ? 1.0 : 0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    // MARK: - Tab 2: Runner Pane
    private var runnerPane: some View {
        @Bindable var pm = proxyManager
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Free LLM Connection Router")
                            .font(.system(size: 13, weight: .bold))
                        Text("Redirect Claude Code traffic to alternative backends. This only affects this app.")
                            .font(.system(size: 11))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        Task {
                            if pm.isRunnerActive {
                                await pm.stopRunner()
                            } else {
                                await pm.startRunner()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pm.isRunnerActive ? "stop.fill" : "play.fill")
                            Text(pm.isRunnerActive ? "Stop Router" : "Start Router")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(pm.isRunnerActive ? Color.red.opacity(0.15) : Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(pm.isRunnerActive ? Color.red : Color.green)
                    }
                    .buttonStyle(.plain)
                }
                
                // Status light: green when ANY process responds on the proxy port
                HStack(spacing: 8) {
                    Circle()
                        .fill(pm.effectiveProxyActive ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((pm.effectiveProxyActive ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                
                VStack(spacing: 12) {
                    HStack {
                        Text("Provider")
                            .font(.system(size: 11))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $pm.selectedProvider) {
                            ForEach(providers, id: \.self) { p in
                                Text(p).tag(p)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: pm.selectedProvider) { _, newProv in
                            pm.selectedModel = defaultModel(for: newProv)
                            pm.saveConfig()
                        }
                    }
                    
                    labeledTextField(label: "Model Name", text: $pm.selectedModel, placeholder: "e.g. qwen2.5-coder:latest")
                    
                    labeledTextField(label: "Port Number", text: Binding(
                        get: { String(pm.proxyPort) },
                        set: { if let p = Int($0) { pm.proxyPort = p } }
                    ), placeholder: "5529")
                    
                    if pm.selectedProvider == "Nvidia NIM" || pm.selectedProvider == "Nemotron 3 Ultra" || pm.selectedProvider == "OpenCode Zen / Big-Pickle" {
                        labeledTextField(label: "API Token / Key", text: $pm.apiKey, placeholder: "nvapi-xxxx...")
                    }
                    
                    if pm.selectedProvider == "Ollama Qwen" {
                        labeledTextField(label: "Ollama Host URL", text: $pm.customHostUrl, placeholder: "http://127.0.0.1:11434")
                    }
                }
                .disabled(pm.isRunnerActive)
                .opacity(pm.isRunnerActive ? 0.7 : 1.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private func labeledTextField(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 120, alignment: .leading)
            
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    proxyManager.saveConfig()
                }
        }
    }
    
    private func defaultModel(for provider: String) -> String {
        switch provider {
        case "OpenCode Zen / Big-Pickle": return "opencode/zen-coder"
        case "Nvidia NIM":                return "nvidia/llama-3.1-nemotron-70b-instruct"
        case "Nemotron 3 Ultra":         return "nvidia/nemotron-3-8b-ultra"
        case "Ollama Qwen":              return "qwen2.5-coder:latest"
        default:                         return "opencode/zen-coder"
        }
    }
}
