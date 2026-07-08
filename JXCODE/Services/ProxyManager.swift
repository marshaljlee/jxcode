import Foundation
import Observation
import SwiftUI
import JXCODECore

@MainActor
@Observable
public class ProxyManager {
    public static let shared = ProxyManager()
    
    // MARK: - State
    public var isRunnerActive: Bool = false
    public var isProxyEnabled: Bool = false
    
    // Tab 1: Config Fields
    public var httpProxy: String = ""
    public var httpsProxy: String = ""
    public var noProxy: String = ""
    public var allProxy: String = ""
    
    // Tab 2: Runner Fields
    public var selectedProvider: String = "OpenCode Zen / Big-Pickle"
    public var selectedModel: String = "opencode/zen-coder"
    public var proxyPort: Int = 5529
    public var apiKey: String = ""
    public var customHostUrl: String = ""
    public var latency: Double = 0.0
    
    // MARK: - Paths
    private var configPath: String {
        return "\(NSHomeDirectory())/.jxproxy/config.env"
    }
    
    private var jxproxyBinary: String? {
        let fm = FileManager.default
        let embedded = Bundle.main.path(forResource: "jxproxy", ofType: nil)
        if let path = embedded, fm.fileExists(atPath: path) {
            return path
        }
        let localBin = "\(NSHomeDirectory())/.local/bin/jxproxy"
        if fm.fileExists(atPath: localBin) {
            return localBin
        }
        return nil
    }
    
    nonisolated(unsafe) private var monitorTask: Task<Void, Never>?
    nonisolated(unsafe) private var process: Process?
    
    private init() {
        loadConfig()
        startMonitoring()
    }
    
    deinit {
        monitorTask?.cancel()
        process?.terminate()
    }
    
    // MARK: - Config Load/Save
    public func loadConfig() {
        let env = EnvFileParser.parse(filePath: configPath)
        
        // Tab 1: System proxies
        self.isProxyEnabled = (env["PROXY_ENABLED"] ?? "false") == "true"
        self.httpProxy = env["HTTP_PROXY"] ?? ""
        self.httpsProxy = env["HTTPS_PROXY"] ?? ""
        self.noProxy = env["NO_PROXY"] ?? ""
        self.allProxy = env["ALL_PROXY"] ?? ""
        
        // Tab 2: Free Runner
        if let portStr = env["JXPROXY_PORT"], let port = Int(portStr) {
            self.proxyPort = port
        } else {
            self.proxyPort = 5529
        }
        
        let providerVal = env["JXPROXY_PROVIDER"] ?? "direct"
        self.selectedProvider = friendlyProviderName(for: providerVal)
        self.selectedModel = env["MODEL"] ?? "opencode/zen-coder"
        self.apiKey = env["OPENAI_API_KEY"] ?? env["NVIDIA_API_KEY"] ?? ""
        self.customHostUrl = env["LOCAL_LLM_BASE_URL"] ?? env["OPENAI_BASE_URL"] ?? ""
        
        self.isRunnerActive = UserDefaults.standard.bool(forKey: "jxcode.proxyRunnerActive")
        if self.isRunnerActive && process == nil {
            // Relaunch runner if it was previously active
            Task {
                await startRunner()
            }
        }
    }
    
    public func saveConfig() {
        do {
            try EnvFileParser.update(filePath: configPath, key: "PROXY_ENABLED", value: isProxyEnabled ? "true" : "false")
            try EnvFileParser.update(filePath: configPath, key: "HTTP_PROXY", value: httpProxy)
            try EnvFileParser.update(filePath: configPath, key: "HTTPS_PROXY", value: httpsProxy)
            try EnvFileParser.update(filePath: configPath, key: "NO_PROXY", value: noProxy)
            try EnvFileParser.update(filePath: configPath, key: "ALL_PROXY", value: allProxy)
            
            try EnvFileParser.update(filePath: configPath, key: "JXPROXY_PORT", value: String(proxyPort))
            
            let providerVal = canonicalProviderValue(for: selectedProvider)
            try EnvFileParser.update(filePath: configPath, key: "JXPROXY_PROVIDER", value: providerVal)
            try EnvFileParser.update(filePath: configPath, key: "MODEL", value: selectedModel)
            
            if selectedProvider == "Nvidia NIM" || selectedProvider == "Nemotron 3 Ultra" {
                try EnvFileParser.update(filePath: configPath, key: "OPENAI_API_KEY", value: apiKey)
                try EnvFileParser.update(filePath: configPath, key: "OPENAI_BASE_URL", value: "https://integrate.api.nvidia.com/v1")
            } else if selectedProvider == "Ollama Qwen" {
                let host = customHostUrl.isEmpty ? "http://127.0.0.1:11434" : customHostUrl
                try EnvFileParser.update(filePath: configPath, key: "LOCAL_LLM_BASE_URL", value: host)
            } else if selectedProvider == "OpenCode Zen / Big-Pickle" {
                try EnvFileParser.update(filePath: configPath, key: "OPENAI_API_KEY", value: apiKey)
            }
        } catch {
            print("Failed to save proxy config: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Runner Controls
    public func startRunner() async {
        saveConfig()
        guard process == nil else { return }
        
        guard let binary = jxproxyBinary else {
            print("jxproxy binary not found on this system!")
            return
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--proxy-only"]
        
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        proc.environment = env
        
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        
        do {
            try proc.run()
            self.process = proc
            self.isRunnerActive = true
            UserDefaults.standard.set(true, forKey: "jxcode.proxyRunnerActive")
            
            try? await Task.sleep(nanoseconds: 1_000_000_000) // wait for server to bind
            await checkStatus()
        } catch {
            print("Failed to start proxy runner process: \(error.localizedDescription)")
        }
    }
    
    public func stopRunner() async {
        process?.terminate()
        process = nil
        self.isRunnerActive = false
        self.latency = 0.0
        UserDefaults.standard.set(false, forKey: "jxcode.proxyRunnerActive")
        
        // Also stop it using CLI if running independently
        if let binary = jxproxyBinary {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = ["--proxy-stop"]
            try? proc.run()
            proc.waitUntilExit()
        }
    }
    
    // MARK: - Monitoring
    private func checkStatus() async {
        guard isRunnerActive else { return }
        let urlString = "http://127.0.0.1:\(proxyPort)/health"
        guard let url = URL(string: urlString) else { return }
        
        let startTime = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                self.latency = Date().timeIntervalSince(startTime) * 1000.0
            } else {
                self.latency = 0.0
            }
        } catch {
            self.latency = 0.0
        }
    }
    
    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                if await self.isRunnerActive {
                    await self.checkStatus()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    
    // MARK: - Helpers
    private func friendlyProviderName(for val: String) -> String {
        switch val {
        case "opencode-zen": return "OpenCode Zen / Big-Pickle"
        case "openai":       return "Nvidia NIM"
        case "local":        return "Ollama Qwen"
        default:
            if val.contains("nemotron") { return "Nemotron 3 Ultra" }
            return "OpenCode Zen / Big-Pickle"
        }
    }
    
    private func canonicalProviderValue(for friendly: String) -> String {
        switch friendly {
        case "OpenCode Zen / Big-Pickle": return "opencode-zen"
        case "Nvidia NIM":                return "openai"
        case "Nemotron 3 Ultra":         return "openai"
        case "Ollama Qwen":              return "local"
        default:                         return "opencode-zen"
        }
    }
}
