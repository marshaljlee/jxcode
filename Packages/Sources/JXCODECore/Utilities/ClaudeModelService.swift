import Foundation

// MARK: - ClaudeModelService

/// Ported from paseo's `model-manifest.ts` and `models.ts`.
/// Provides a static Claude model manifest, alias resolution, and
/// async settings.json model discovery.
public enum ClaudeModelService {

    // MARK: - Manifest Entry (private)

    private struct ManifestEntry: Hashable, Sendable {
        let id: String
        let label: String
        let descriptionText: String
        let isDefault: Bool
        let supportsFastMode: Bool
    }

    // MARK: - Canonical Manifest

    /// 11-model manifest sourced from paseo's `CLAUDE_MODEL_MANIFEST`.
    /// Opus 4.8 is the default.
    private static let manifest: [ManifestEntry] = [
        ManifestEntry(
            id: "claude-fable-5",
            label: "Fable 5",
            descriptionText: "Fable 5 · Most powerful model",
            isDefault: false,
            supportsFastMode: false
        ),
        ManifestEntry(
            id: "claude-opus-4-8[1m]",
            label: "Opus 4.8 1M",
            descriptionText: "Opus 4.8 with 1M context window",
            isDefault: false,
            supportsFastMode: true
        ),
        ManifestEntry(
            id: "claude-opus-4-8",
            label: "Opus 4.8",
            descriptionText: "Opus 4.8 · Latest release",
            isDefault: true,
            supportsFastMode: true
        ),
        ManifestEntry(
            id: "claude-sonnet-5",
            label: "Sonnet 5",
            descriptionText: "Sonnet 5 · Best for everyday tasks",
            isDefault: false,
            supportsFastMode: false
        ),
        ManifestEntry(
            id: "claude-opus-4-7[1m]",
            label: "Opus 4.7 1M",
            descriptionText: "Opus 4.7 with 1M context window",
            isDefault: false,
            supportsFastMode: true
        ),
        ManifestEntry(
            id: "claude-opus-4-7",
            label: "Opus 4.7",
            descriptionText: "Opus 4.7 · Previous release",
            isDefault: false,
            supportsFastMode: true
        ),
        ManifestEntry(
            id: "claude-opus-4-6[1m]",
            label: "Opus 4.6 1M",
            descriptionText: "Opus 4.6 with 1M context window",
            isDefault: false,
            supportsFastMode: true
        ),
        ManifestEntry(
            id: "claude-opus-4-6",
            label: "Opus 4.6",
            descriptionText: "Opus 4.6 · Most capable for complex work",
            isDefault: false,
            supportsFastMode: true
        ),
        ManifestEntry(
            id: "claude-sonnet-4-6[1m]",
            label: "Sonnet 4.6 1M",
            descriptionText: "Sonnet 4.6 with 1M context window",
            isDefault: false,
            supportsFastMode: false
        ),
        ManifestEntry(
            id: "claude-sonnet-4-6",
            label: "Sonnet 4.6",
            descriptionText: "Sonnet 4.6 · Best for everyday tasks",
            isDefault: false,
            supportsFastMode: false
        ),
        ManifestEntry(
            id: "claude-haiku-4-5",
            label: "Haiku 4.5",
            descriptionText: "Haiku 4.5 · Fastest for quick answers",
            isDefault: false,
            supportsFastMode: false
        ),
    ]

    // MARK: - Alias Map

    /// Short aliases resolve to canonical manifest IDs.
    /// Ported from paseo's settings-model resolution logic.
    private static let aliasToCanonical: [String: String] = [
        "default": "claude-opus-4-8",
        "best": "claude-opus-4-8",
        "opus": "claude-opus-4-8",
        "sonnet": "claude-sonnet-5",
        "haiku": "claude-haiku-4-5",
        "opus[1m]": "claude-opus-4-8[1m]",
        "sonnet[1m]": "claude-sonnet-4-6[1m]",
        "opusplan": "claude-opus-4-8",
    ]

    // MARK: - Settings Extra Models

    /// Custom models discovered from `~/.claude/settings.json`.
    /// Populated once at app start via `loadSettingsModels()`.
    nonisolated(unsafe) public private(set) static var extraModels: [ClaudeModelDefinition] = []

    // MARK: - Public API

    /// All canonical model IDs from the manifest, plus any extras loaded from settings.json.
    public static var allModelIds: [String] {
        manifest.map(\.id) + extraModels.map(\.id)
    }

    /// Look up the display label for a model ID.
    /// Checks manifest first, then extra models, then returns nil.
    public static func displayName(for id: String) -> String? {
        if let entry = findManifestEntry(id) { return entry.label }
        if let extra = extraModels.first(where: { $0.id == id }) { return extra.label }
        return nil
    }

    /// Look up the description text for a model ID.
    /// Checks manifest first, then extra models, then returns nil.
    public static func description(for id: String) -> String? {
        if let entry = findManifestEntry(id) { return entry.descriptionText }
        if let extra = extraModels.first(where: { $0.id == id }) { return extra.descriptionText }
        return nil
    }

    /// Find a model definition by id (alias or canonical).
    /// Returns the manifest or extra-model entry, or nil.
    public static func findModel(_ id: String) -> ClaudeModelDefinition? {
        let canonical = resolveAlias(id)
        if let entry = findManifestEntry(canonical) {
            return ClaudeModelDefinition(
                provider: "claude",
                id: entry.id,
                label: entry.label,
                descriptionText: entry.descriptionText,
                isDefault: entry.isDefault,
                contextWindowMaxTokens: 200_000,
                supportsFastMode: entry.supportsFastMode
            )
        }
        return extraModels.first { $0.id == canonical }
    }

    /// Resolve a user-facing alias (e.g. "opus") to its canonical manifest ID
    /// (e.g. "claude-opus-4-8"). If the input is not a known alias it is returned
    /// unchanged, so the function is idempotent.
    public static func resolveAlias(_ id: String) -> String {
        let lower = id.lowercased().trimmingCharacters(in: .whitespaces)
        return aliasToCanonical[lower] ?? id
    }

    /// Whether the manifest entry supports fast mode.
    public static func supportsFastMode(_ id: String) -> Bool {
        let canonical = resolveAlias(id)
        return manifest.first { $0.id == canonical }?.supportsFastMode ?? false
    }

    // MARK: - Settings.json Loading

    /// Path to the Claude config directory (`CLAUDE_CONFIG_DIR` or `~/.claude`).
    public static func claudeConfigDirPath() -> String {
        if let envConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return envConfigDir
        }
        return (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }

    /// Read `~/.claude/settings.json` and extract any model entries not already in the manifest.
    /// Ported from paseo's `readClaudeSettingsModels()`.
    public static func readClaudeSettingsModels() async -> [ClaudeModelDefinition] {
        let settingsPath = claudeConfigDirPath() + "/settings.json"
        let url = URL(fileURLWithPath: settingsPath)

        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        guard let dict = json as? [String: Any] else { return [] }

        var seenIds = Set(manifest.map(\.id))
        var result: [ClaudeModelDefinition] = []

        // Helper: add model if not already seen
        func addIfNew(_ id: String, label: String, description: String) {
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seenIds.contains(trimmed) else { return }
            seenIds.insert(trimmed)
            result.append(ClaudeModelDefinition(
                id: trimmed,
                label: label,
                descriptionText: description,
                isDefault: false
            ))
        }

        // settings.model
        if let modelStr = dict["model"] as? String {
            addIfNew(modelStr, label: modelStr, description: "From Claude settings.json model")
        }

        // settings.env.*
        let envKeys = [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        ]

        if let env = dict["env"] as? [String: Any] {
            for key in envKeys {
                if let val = env[key] as? String {
                    addIfNew(val, label: val, description: "From Claude settings.json env.\(key)")
                }
            }
        }

        return result
    }

    /// Load extra models from settings.json and cache them in `extraModels`.
    /// Call once at app start from `AppState.initialize()`.
    public static func loadSettingsModels() async {
        extraModels = await readClaudeSettingsModels()
    }

    // MARK: - Private Helpers

    private static func findManifestEntry(_ id: String) -> ManifestEntry? {
        manifest.first { $0.id == id }
    }

    private static func manifestContains(_ id: String) -> Bool {
        manifest.contains { $0.id == id }
    }
}
