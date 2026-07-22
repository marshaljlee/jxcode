import Foundation
import Observation
import SwiftUI
import OSLog

// MARK: - Proxy Manager
// Merged: JXRouter's actor-based architecture + jxcode's minute config and SwiftUI compatibility.

@MainActor
@Observable
public final class ProxyManager {
    public static let shared = ProxyManager()
    private let log = Logger(subsystem: "com.jxcode", category: "proxy")

    // MARK: - Runner State

    public internal(set) var runnerStatus: ProxyStatus = .stopped
    public internal(set) var stats = ProxyStats()
    public internal(set) var logEntries: [ProxyLogEntry] = []
    public var isRunnerActive: Bool = false
    public var isPortActive: Bool = false
    public var latency: Double = 0.0

    public var effectiveProxyActive: Bool { isRunnerActive || isPortActive }

    // MARK: - Process Management

    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var stdoutPipe: Pipe?
    nonisolated(unsafe) private var stderrPipe: Pipe?
    nonisolated(unsafe) private var healthCheckTask: Task<Void, Never>?
    private var startedAt: Date?

    // MARK: - Config

    public var config: ProxyConfig = .default {
        didSet { isConfigDirty = true }
    }
    public var isConfigDirty: Bool = false

    /// Convenience accessors for SwiftUI bindings
    public var proxyPort: Int {
        get { config.port }
        set { config.port = newValue; saveConfig() }
    }
    public var selectedProvider: String {
        get { config.provider.rawValue }
        set {
            if let p = ProxyConfig.Provider.allCases.first(where: { $0.rawValue == newValue }) {
                config.provider = p
                config.model = p.defaultModel
                saveConfig()
            }
        }
    }
    public var selectedModel: String {
        get { config.model }
        set { config.model = newValue; saveConfig() }
    }
    public var apiKey: String {
        get { config.apiKeys[config.provider] ?? "" }
        set { config.apiKeys[config.provider] = newValue; saveConfig() }
    }
    public var customHostUrl: String = ""
    public var fallbackProviders: [String] {
        get { config.fallbackProviders.map(\.rawValue) }
        set {
            config.fallbackProviders = newValue.compactMap { v in
                ProxyConfig.Provider.allCases.first { $0.rawValue == v }
            }
            saveConfig()
        }
    }
    public var logLevel: String {
        get { config.logLevel.rawValue }
        set {
            if let l = ProxyConfig.LogLevel(rawValue: newValue) { config.logLevel = l; saveConfig() }
        }
    }
    public var requestTimeoutSeconds: Int {
        get { config.requestTimeoutSeconds }
        set { config.requestTimeoutSeconds = newValue; saveConfig() }
    }
    public var launchAtLogin: Bool {
        get { config.launchAtLogin }
        set { config.launchAtLogin = newValue; saveConfig() }
    }
    public var proxyAllTraffic: Bool {
        get { config.proxyAllTraffic }
        set { config.proxyAllTraffic = newValue; saveConfig() }
    }
    public var isProxyEnabled: Bool {
        get { config.isProxyEnabled }
        set { config.isProxyEnabled = newValue; saveConfig() }
    }
    public var httpProxy: String {
        get { config.httpProxy }
        set { config.httpProxy = newValue; saveConfig() }
    }
    public var httpsProxy: String {
        get { config.httpsProxy }
        set { config.httpsProxy = newValue; saveConfig() }
    }
    public var noProxy: String {
        get { config.noProxy }
        set { config.noProxy = newValue; saveConfig() }
    }
    public var allProxy: String {
        get { config.allProxy }
        set { config.allProxy = newValue; saveConfig() }
    }

    private var configPath: String {
        "\(NSHomeDirectory())/.jxproxy/config.env"
    }

    public var jxproxyBinary: String? {
        let fm = FileManager.default
        let embedded = Bundle.main.path(forResource: "jxproxy", ofType: nil)
        if let path = embedded, fm.fileExists(atPath: path) { return path }
        let homeBin = "\(NSHomeDirectory())/.local/bin/jxproxy"
        if fm.fileExists(atPath: homeBin) { return homeBin }
        let brewBin = "/opt/homebrew/bin/jxproxy"
        if fm.fileExists(atPath: brewBin) { return brewBin }
        let usrLocalBin = "/usr/local/bin/jxproxy"
        if fm.fileExists(atPath: usrLocalBin) { return usrLocalBin }
        return nil
    }

    private init() {
        loadConfig()
        startMonitoring()
    }

    deinit {
        healthCheckTask?.cancel()
        process?.terminate()
    }

    // MARK: - Config Load / Save

    public func loadConfig() {
        loadConfigFromFile()
        isRunnerActive = UserDefaults.standard.bool(forKey: "jxcode.proxyRunnerActive")
        if isRunnerActive && process == nil {
            Task { await startRunner() }
        }
    }

    public func saveConfig() {
        do {
            try EnvFileParser.update(filePath: configPath, key: "PROXY_ENABLED", value: config.isProxyEnabled ? "true" : "false")
            try EnvFileParser.update(filePath: configPath, key: "HTTP_PROXY", value: config.isProxyEnabled ? config.httpProxy : "")
            try EnvFileParser.update(filePath: configPath, key: "HTTPS_PROXY", value: config.isProxyEnabled ? config.httpsProxy : "")
            try EnvFileParser.update(filePath: configPath, key: "NO_PROXY", value: config.isProxyEnabled ? config.noProxy : "")
            try EnvFileParser.update(filePath: configPath, key: "ALL_PROXY", value: config.isProxyEnabled ? config.allProxy : "")

            try EnvFileParser.update(filePath: configPath, key: "JXPROXY_PORT", value: String(config.port))
            try EnvFileParser.update(filePath: configPath, key: "ANTHROPIC_BASE_URL", value: "http://127.0.0.1:\(config.port)/v1")
            try EnvFileParser.update(filePath: configPath, key: "JXPROXY_PROVIDER", value: config.provider.identifier)
            try EnvFileParser.update(filePath: configPath, key: "MODEL", value: config.model)

            let fallbackStr = config.fallbackProviders.map(\.identifier).joined(separator: ",")
            try EnvFileParser.update(filePath: configPath, key: "FALLBACK_PROVIDERS", value: fallbackStr)
            try EnvFileParser.update(filePath: configPath, key: "LOG_LEVEL", value: config.logLevel.rawValue)
            try EnvFileParser.update(filePath: configPath, key: "REQUEST_TIMEOUT", value: String(config.requestTimeoutSeconds))
            try EnvFileParser.update(filePath: configPath, key: "LAUNCH_AT_LOGIN", value: config.launchAtLogin ? "true" : "false")
            try EnvFileParser.update(filePath: configPath, key: "PROXY_ALL_TRAFFIC", value: config.proxyAllTraffic ? "true" : "false")

            // Provider-specific keys
            switch config.provider {
            case .opencodeZen, .openai, .nemotron:
                if let key = config.apiKeys[config.provider], !key.isEmpty {
                    try EnvFileParser.update(filePath: configPath, key: "OPENAI_API_KEY", value: key)
                }
            case .local:
                let host = customHostUrl.isEmpty ? "http://127.0.0.1:11434" : customHostUrl
                try EnvFileParser.update(filePath: configPath, key: "LOCAL_LLM_BASE_URL", value: host)
            default:
                break
            }

            isConfigDirty = false
            addLog(.info, "Configuration saved")
        } catch {
            addLog(.error, "Failed to save config: \(error.localizedDescription)")
        }
    }

    private func loadConfigFromFile() {
        let env = EnvFileParser.parse(filePath: configPath)
        config.isProxyEnabled = (env["PROXY_ENABLED"] ?? "false") == "true"
        config.httpProxy = env["HTTP_PROXY"] ?? ""
        config.httpsProxy = env["HTTPS_PROXY"] ?? ""
        config.noProxy = env["NO_PROXY"] ?? ""
        config.allProxy = env["ALL_PROXY"] ?? ""

        if let portStr = env["JXPROXY_PORT"], let port = Int(portStr) { config.port = port }
        else { config.port = 5255 }

        let providerVal = env["JXPROXY_PROVIDER"] ?? "opencode-zen"
        config.provider = matchProvider(providerVal)
        config.model = env["MODEL"] ?? config.provider.defaultModel
        config.apiKeys[.opencodeZen] = env["OPENAI_API_KEY"] ?? ""
        config.apiKeys[.openai] = env["OPENAI_API_KEY"] ?? ""
        config.apiKeys[.nemotron] = env["OPENAI_API_KEY"] ?? ""

        customHostUrl = env["LOCAL_LLM_BASE_URL"] ?? env["OPENAI_BASE_URL"] ?? ""

        let fallbackRaw = env["FALLBACK_PROVIDERS"] ?? ""
        config.fallbackProviders = fallbackRaw.split(separator: ",").compactMap {
            matchProvider(String($0))
        }
        if let logRaw = env["LOG_LEVEL"], let l = ProxyConfig.LogLevel(rawValue: logRaw) { config.logLevel = l }
        if let tStr = env["REQUEST_TIMEOUT"], let t = Int(tStr) { config.requestTimeoutSeconds = t }
        config.launchAtLogin = (env["LAUNCH_AT_LOGIN"] ?? "false") == "true"
        config.proxyAllTraffic = (env["PROXY_ALL_TRAFFIC"] ?? "false") == "true"
    }

    private func matchProvider(_ val: String) -> ProxyConfig.Provider {
        switch val.lowercased() {
        case "direct": return .direct
        case "openrouter": return .openrouter
        case "opencode-zen": return .opencodeZen
        case "opencode-go": return .opencodeGo
        case "openai": return .openai
        case "local": return .local
        case _ where val.contains("nemotron"): return .nemotron
        default: return .opencodeZen
        }
    }

    // MARK: - Runner Controls

    public func startRunner() async {
        guard !runnerStatus.isActive else {
            log.notice("Proxy already running, ignoring start")
            return
        }

        runnerStatus = .starting(progress: 0.2)
        isProxyEnabled = true
        startedAt = Date()
        saveConfig()
        guard process == nil else { return }

        guard let binary = jxproxyBinary else {
            addLog(.error, "jxproxy binary not found")
            runnerStatus = .failed(error: "jxproxy binary not found. Install jxproxy first or place it in PATH.")
            return
        }

        runnerStatus = .starting(progress: 0.5)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["server", "--port", String(config.port)]

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["JXPROXY_PORT"] = String(config.port)
        env["JXPROXY_PROVIDER"] = config.provider.identifier
        env["MODEL"] = config.model
        env["CLAUDE_CODE_DISABLE_TELEMETRY"] = "true"
        env["OTEL_SDK_DISABLED"] = "true"

        if !config.fallbackProviders.isEmpty {
            env["FALLBACK_PROVIDERS"] = config.fallbackProviders.map(\.identifier).joined(separator: ",")
        }
        for (provider, key) in config.apiKeys where !key.isEmpty {
            switch provider {
            case .direct: env["ANTHROPIC_API_KEY"] = key
            case .openrouter: env["OPENROUTER_API_KEY"] = key
            case .openai, .nemotron, .opencodeZen: env["OPENAI_API_KEY"] = key
            default: break
            }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = proc.terminationStatus
                if status == 0 {
                    self.transitionToStopped()
                } else {
                    let reason = self.readStderr(from: stderrPipe)
                    self.transitionToFailed("Process exited with code \(status): \(reason)")
                }
            }
        }

        self.process = proc
        proc.qualityOfService = .userInitiated

        do {
            try proc.run()
            self.process = proc
            self.isRunnerActive = true
            UserDefaults.standard.set(true, forKey: "jxcode.proxyRunnerActive")
            addLog(.info, "Proxy runner started on port \(config.port)")

            runnerStatus = .starting(progress: 0.8)

            // Health check loop
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            for i in 0..<15 {
                if Task.isCancelled { return }
                await checkHealth()
                if isPortActive {
                    let pid = Int(proc.processIdentifier)
                    runnerStatus = .running(pid: pid, uptime: 0, port: config.port)
                    stats.startTime = Date()
                    addLog(.info, "Proxy health check passed on port \(config.port)")
                    startStatsPolling()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            addLog(.warn, "Proxy started but health check not yet passing")
            runnerStatus = .starting(progress: 0.9)
            stats.startTime = Date()
            startStatsPolling()
        } catch {
            addLog(.error, "Failed to start runner: \(error.localizedDescription)")
            runnerStatus = .failed(error: "Failed to start: \(error.localizedDescription)")
        }
    }

    public func stopRunner() async {
        guard case .running = runnerStatus else {
            if case .starting = runnerStatus {
                healthCheckTask?.cancel()
                process?.terminate()
                process = nil
                transitionToStopped()
            }
            return
        }

        runnerStatus = .stopping
        addLog(.info, "Stopping proxy runner")

        process?.interrupt()

        for _ in 0..<5 {
            if let proc = process, !proc.isRunning {
                process = nil
                transitionToStopped()
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        process?.terminate()
        process = nil
        transitionToStopped()

        if let binary = jxproxyBinary {
            let stopProc = Process()
            stopProc.executableURL = URL(fileURLWithPath: binary)
            stopProc.arguments = ["--proxy-stop"]
            try? stopProc.run()
            stopProc.waitUntilExit()
        }
    }

    public func restartRunner() async {
        await stopRunner()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await startRunner()
    }

    // MARK: - Environment Variables

    public func loadEnvVars() -> [(key: String, value: String, source: String, sensitive: Bool)] {
        let env = ProcessInfo.processInfo.environment
        let keys = [
            "JXPROXY_PORT", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
            "JXPROXY_PROVIDER", "MODEL", "FALLBACK_PROVIDERS",
            "OPENAI_API_KEY", "OPENROUTER_API_KEY",
            "LOG_LEVEL", "REQUEST_TIMEOUT",
            "CLAUDE_CODE_DISABLE_TELEMETRY", "OTEL_SDK_DISABLED"
        ]
        let sensitive = Set(["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "NVIDIA_API_KEY"])
        let fileEnv = EnvFileParser.parse(filePath: configPath)
        return keys.map { key in
            let val = env[key] ?? fileEnv[key] ?? ""
            let source: String = env[key] != nil ? "System" : (fileEnv[key] != nil ? "Config" : "Default")
            return (key, val, source, sensitive.contains(key))
        }
    }

    public func updateEnvVar(key: String, value: String) {
        do {
            try EnvFileParser.update(filePath: configPath, key: key, value: value)
            addLog(.info, "Updated env var: \(key)")
            loadConfig()
        } catch {
            addLog(.error, "Failed to update \(key): \(error.localizedDescription)")
        }
    }

    // MARK: - Logs

    public func addLog(_ level: ProxyConfig.LogLevel, _ message: String) {
        let entry = ProxyLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            message: message,
            source: "proxy"
        )
        logEntries.append(entry)
        if logEntries.count > 500 { logEntries.removeFirst(logEntries.count - 500) }
    }

    public func clearLogs() {
        logEntries.removeAll()
    }

    // MARK: - Health Monitoring

    private func checkHealth() async {
        let urlString = "http://127.0.0.1:\(config.port)/health"
        guard let url = URL(string: urlString) else { return }
        let startTime = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                latency = Date().timeIntervalSince(startTime) * 1000.0
                isPortActive = true
            } else {
                latency = 0.0
                isPortActive = false
            }
        } catch {
            latency = 0.0
            isPortActive = false
        }
    }

    private func startStatsPolling() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.checkHealth()
                if self.runnerStatus.isActive, let start = self.stats.startTime {
                    self.stats.uptimeSeconds = Date().timeIntervalSince(start)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func startMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.runnerStatus.isActive {
                    await self.checkHealth()
                    if let start = self.stats.startTime {
                        self.stats.uptimeSeconds = Date().timeIntervalSince(start)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: - Helpers

    private func transitionToStopped() {
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunnerActive = false
        runnerStatus = .stopped
        stats.startTime = nil
        UserDefaults.standard.set(false, forKey: "jxcode.proxyRunnerActive")
    }

    private func transitionToFailed(_ error: String) {
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        isRunnerActive = false
        runnerStatus = .failed(error: error)
    }

    private func readStderr(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
    }
}
