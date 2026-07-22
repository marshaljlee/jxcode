import Foundation

// MARK: - Proxy Configuration
// Merged from JXRouter's rich model with jxcode's minute provider configuration.

public struct ProxyConfig: Codable, Equatable {
    public var port: Int
    public var provider: Provider
    public var model: String
    public var fallbackProviders: [Provider]
    public var apiKeys: [Provider: String]
    public var logLevel: LogLevel
    public var autoStart: Bool
    public var launchAtLogin: Bool
    public var proxyAllTraffic: Bool
    public var requestTimeoutSeconds: Int

    /// System proxy settings
    public var httpProxy: String = ""
    public var httpsProxy: String = ""
    public var noProxy: String = ""
    public var allProxy: String = ""
    public var isProxyEnabled: Bool = false

    /// Custom host for local providers
    public var customHostUrl: String = ""

    public init(port: Int, provider: Provider, model: String, fallbackProviders: [Provider], apiKeys: [Provider: String], logLevel: LogLevel, autoStart: Bool, launchAtLogin: Bool, proxyAllTraffic: Bool, requestTimeoutSeconds: Int) {
        self.port = port
        self.provider = provider
        self.model = model
        self.fallbackProviders = fallbackProviders
        self.apiKeys = apiKeys
        self.logLevel = logLevel
        self.autoStart = autoStart
        self.launchAtLogin = launchAtLogin
        self.proxyAllTraffic = proxyAllTraffic
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public static let `default` = ProxyConfig(
        port: 5255,
        provider: .opencodeZen,
        model: "opencode/zen-coder",
        fallbackProviders: [.openrouter],
        apiKeys: [:],
        logLevel: .info,
        autoStart: false,
        launchAtLogin: false,
        proxyAllTraffic: false,
        requestTimeoutSeconds: 30
    )

    public enum Provider: String, Codable, CaseIterable, Identifiable {
        case direct = "Anthropic Direct"
        case openrouter = "OpenRouter"
        case opencodeZen = "OpenCode Zen / Big-Pickle"
        case opencodeGo = "OpenCode Go"
        case openai = "Nvidia NIM"
        case nemotron = "Nemotron 3 Ultra"
        case local = "Ollama Qwen"

        public var id: String { rawValue }

        public var identifier: String {
            switch self {
            case .direct: return "direct"
            case .openrouter: return "openrouter"
            case .opencodeZen: return "opencode-zen"
            case .opencodeGo: return "opencode-go"
            case .openai: return "openai"
            case .nemotron: return "openai"
            case .local: return "local"
            }
        }

        public var requiresKey: Bool { self != .local }

        public var defaultEndpoint: String {
            switch self {
            case .direct: return "https://api.anthropic.com"
            case .openrouter: return "https://openrouter.ai/api/v1"
            case .opencodeZen: return "https://opencode.ai/zen/v1"
            case .opencodeGo: return "https://opencode.ai/zen/go/v1"
            case .openai, .nemotron: return "https://integrate.api.nvidia.com/v1"
            case .local: return "http://127.0.0.1:11434"
            }
        }

        public var defaultModel: String {
            switch self {
            case .direct: return "claude-sonnet-5-20251001"
            case .openrouter: return "openrouter/auto"
            case .opencodeZen: return "opencode/zen-coder"
            case .opencodeGo: return "opencode/go-coder"
            case .openai: return "nvidia/llama-3.1-nemotron-70b-instruct"
            case .nemotron: return "nvidia/nemotron-3-8b-ultra"
            case .local: return "qwen2.5-coder:latest"
            }
        }
    }

    public enum LogLevel: String, Codable, CaseIterable, Identifiable {
        case debug, info, warn, error
        public var id: String { rawValue }
    }
}
