import Foundation

// MARK: - ClaudeModelDefinition

/// A single model entry, ported from paseo's `AgentModelDefinition`.
/// Carries provider-scoped id, human-readable label, description,
/// and optional capability flags.
public struct ClaudeModelDefinition: Codable, Sendable, Identifiable, Hashable {
    public let provider: String
    public let id: String
    public let label: String
    public let descriptionText: String
    public let isDefault: Bool
    public let contextWindowMaxTokens: Int?
    public let supportsFastMode: Bool?

    public init(
        provider: String = "claude",
        id: String,
        label: String,
        descriptionText: String,
        isDefault: Bool = false,
        contextWindowMaxTokens: Int? = nil,
        supportsFastMode: Bool? = nil
    ) {
        self.provider = provider
        self.id = id
        self.label = label
        self.descriptionText = descriptionText
        self.isDefault = isDefault
        self.contextWindowMaxTokens = contextWindowMaxTokens
        self.supportsFastMode = supportsFastMode
    }
}
