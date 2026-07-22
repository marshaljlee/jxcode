import Foundation
import OSLog

// MARK: - Environment Manager
// From JXRouter — manages ~/.jxproxy/config.env with system overlay.

actor EnvManager {
    static let shared = EnvManager()
    private let log = Logger(subsystem: "com.jxcode", category: "env")

    private let configFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".jxproxy/config.env")
    }()

    struct EnvVar: Identifiable, Equatable {
        let id: String
        let key: String
        var value: String
        let isSensitive: Bool
        var source: EnvSource
        let description: String

        enum EnvSource: String {
            case proxyConfig = "Proxy Config"
            case system = "System"
            case user = "User Set"
            case `default` = "Default"
        }
    }

    private(set) var variables: [EnvVar] = []

    private init() {
        self.variables = Self.defaultVariables
    }

    func load() async {
        let env = ProcessInfo.processInfo.environment
        var loaded = Self.defaultVariables

        // Overlay system environment values
        for i in loaded.indices {
            if let sysVal = env[loaded[i].key] {
                loaded[i].value = sysVal
                loaded[i].source = .system
            }
        }

        // Overlay config file values
        if let configVars = try? loadConfigFile() {
            for configVar in configVars {
                if let idx = loaded.firstIndex(where: { $0.key == configVar.key }) {
                    loaded[idx].value = configVar.value
                    loaded[idx].source = .user
                } else {
                    loaded.append(configVar)
                }
            }
        }

        variables = loaded
    }

    func updateVariable(id: String, value: String) async {
        guard let idx = variables.firstIndex(where: { $0.id == id }) else { return }
        variables[idx].value = value
        variables[idx].source = .user
        try? saveToConfigFile()
    }

    func updateVariable(key: String, value: String) async {
        if let idx = variables.firstIndex(where: { $0.key == key }) {
            variables[idx].value = value
            variables[idx].source = .user
        } else {
            let newVar = EnvVar(
                id: key,
                key: key,
                value: value,
                isSensitive: Self.sensitiveKeys.contains(key),
                source: .user,
                description: "Custom variable"
            )
            variables.append(newVar)
        }
        try? saveToConfigFile()
    }

    func resetToDefaults() async {
        variables = Self.defaultVariables
        try? saveToConfigFile()
    }

    // MARK: - Config File I/O

    private func loadConfigFile() throws -> [EnvVar] {
        let data = try Data(contentsOf: configFileURL)
        let content = String(data: data, encoding: .utf8) ?? ""
        return content
            .components(separatedBy: .newlines)
            .filter { $0.contains("=") && !$0.hasPrefix("#") }
            .compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return EnvVar(
                    id: key,
                    key: key,
                    value: value,
                    isSensitive: Self.sensitiveKeys.contains(key),
                    source: .user,
                    description: Self.descriptions[key] ?? "From config file"
                )
            }
    }

    private func saveToConfigFile() throws {
        let lines = variables
            .filter { $0.source != .default }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let dir = configFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Defaults

    private static let sensitiveKeys: Set<String> = [
        "ANTHROPIC_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY",
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "NVIDIA_API_KEY"
    ]

    private static let descriptions: [String: String] = [
        "JXPROXY_PORT": "Proxy server listening port",
        "JXPROXY_PROVIDER": "Primary AI provider",
        "MODEL": "Default model identifier",
        "FALLBACK_PROVIDERS": "Comma-separated fallback providers",
        "ANTHROPIC_API_KEY": "Anthropic API authentication key",
        "OPENROUTER_API_KEY": "OpenRouter API authentication key",
        "OPENAI_API_KEY": "OpenAI API authentication key",
        "NVIDIA_API_KEY": "Nvidia NIM API key",
        "CLAUDE_CODE_DISABLE_TELEMETRY": "Disables Claude Code telemetry",
        "OTEL_SDK_DISABLED": "Disables OpenTelemetry SDK",
    ]

    static let defaultVariables: [EnvVar] = [
        EnvVar(id: "JXPROXY_PORT", key: "JXPROXY_PORT", value: "5255", isSensitive: false, source: .default, description: "Proxy server listening port"),
        EnvVar(id: "JXPROXY_PROVIDER", key: "JXPROXY_PROVIDER", value: "opencode-zen", isSensitive: false, source: .default, description: "Primary AI provider"),
        EnvVar(id: "MODEL", key: "MODEL", value: "opencode/zen-coder", isSensitive: false, source: .default, description: "Default model identifier"),
        EnvVar(id: "FALLBACK_PROVIDERS", key: "FALLBACK_PROVIDERS", value: "", isSensitive: false, source: .default, description: "Comma-separated fallback providers"),
        EnvVar(id: "ANTHROPIC_API_KEY", key: "ANTHROPIC_API_KEY", value: "", isSensitive: true, source: .default, description: "Anthropic API authentication key"),
        EnvVar(id: "OPENROUTER_API_KEY", key: "OPENROUTER_API_KEY", value: "", isSensitive: true, source: .default, description: "OpenRouter API authentication key"),
        EnvVar(id: "OPENAI_API_KEY", key: "OPENAI_API_KEY", value: "", isSensitive: true, source: .default, description: "OpenAI API authentication key"),
        EnvVar(id: "NVIDIA_API_KEY", key: "NVIDIA_API_KEY", value: "", isSensitive: true, source: .default, description: "Nvidia NIM API key"),
        EnvVar(id: "CLAUDE_CODE_DISABLE_TELEMETRY", key: "CLAUDE_CODE_DISABLE_TELEMETRY", value: "true", isSensitive: false, source: .default, description: "Disables Claude Code telemetry"),
        EnvVar(id: "OTEL_SDK_DISABLED", key: "OTEL_SDK_DISABLED", value: "true", isSensitive: false, source: .default, description: "Disables OpenTelemetry SDK"),
    ]
}
