import Foundation

/// Which wire an agent speaks to the router.
///
/// The router serves three, and they are not interchangeable: a client that
/// speaks Messages cannot be answered with Responses events, and a client that
/// speaks Responses cannot be answered with `content_block_delta`. Until now
/// the wire was implied by the agent's `routerBinding` — Claude Code means
/// Messages, Codex means whatever `wire_api` happened to say — which was fine
/// while there was exactly one sensible value per agent.
///
/// Codex is why that stopped being true. OpenAI deprecated `chat/completions`
/// for Codex on 2025-12-09 and removed it in early February 2026, so
/// `wire_api = "chat"` is a hard startup error and `responses` is the only
/// value a current Codex accepts. Two kinds of user still need to say which
/// wire they want, per agent, rather than have this file decide:
///
///  - someone pinned to a Codex old enough to still accept `chat`, which is the
///    documented escape hatch when a backend's `responses` streaming is broken;
///  - someone whose backend serves one wire and not the other, who needs the
///    mismatch to be visible rather than silently mis-bound.
///
/// Nothing here is inferred from a version number. `isUsableByCurrentCodex`
/// encodes a date from the vendor's own deprecation notice, because that is
/// what the notice states.
public enum AgentWire: String, Codable, Sendable, CaseIterable {

    /// OpenAI's Responses API — `/v1/responses`. What a current Codex requires.
    case responses

    /// OpenAI's Chat Completions API — `/v1/chat/completions`.
    case chat

    /// Anthropic's Messages API — `/v1/messages`.
    case messages

    /// The value Codex's `config.toml` expects, or `nil` where Codex cannot use
    /// this wire at all.
    ///
    /// `nil` rather than a made-up string: Codex has no Messages wire, so a
    /// user who asks for one is asking for something that does not exist, and
    /// the caller reports that instead of writing a config that cannot start.
    public var codexWireAPI: String? {
        switch self {
        case .responses: return "responses"
        case .chat:      return "chat"
        case .messages:  return nil
        }
    }

    /// Whether a current Codex accepts this value.
    ///
    /// `chat/completions` support was removed in early February 2026 and the
    /// value became a hard startup error, so writing it today produces a config
    /// Codex refuses to load. It is still written when asked for — a user on an
    /// older Codex may need it, and silently substituting `responses` would
    /// break exactly the case the override exists for — but it is always
    /// accompanied by a note saying what will happen.
    public var isUsableByCurrentCodex: Bool { self == .responses }

    /// The wire Codex is given when the user names none.
    ///
    /// `responses`, because that is the only value a current Codex accepts. The
    /// previous hardcoded value was `chat`, which is now a startup error — the
    /// defect this override was built around.
    public static let codexDefault: AgentWire = .responses

    public var displayName: String {
        switch self {
        case .responses: return "OpenAI Responses"
        case .chat:      return "OpenAI Chat Completions"
        case .messages:  return "Anthropic Messages"
        }
    }

    /// Parse the spelling a user types on a command line or into a field.
    ///
    /// Accepts the aliases people reach for rather than only the canonical
    /// spelling, because "which of these three" is not worth a failed command:
    /// `chat_completions`, `anthropic` and `response` all name exactly one wire.
    public static func parse(_ raw: String) -> AgentWire? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "responses", "response":
            return .responses
        case "chat", "chatcompletions", "chat_completions", "chat-completions":
            return .chat
        case "messages", "message", "anthropic":
            return .messages
        default:
            return nil
        }
    }

    /// The canonical spelling, for an error message that tells the user what to
    /// type instead.
    public static var acceptedSpellings: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}
