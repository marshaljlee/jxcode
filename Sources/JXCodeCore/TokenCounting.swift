import Foundation

/// A token count, and where it came from.
///
/// The provenance is not decoration. Claude Code decides when to compact its
/// context from this number, so "18 tokens, counted by the server that will
/// read them" and "18 tokens, guessed from character counts" call for different
/// amounts of trust — and until now every answer this router gave was the
/// second one, whether or not the backend could have answered the first.
///
/// It is carried on the value rather than inferred at the call site because the
/// call site cannot tell: both paths end in an `Int`, and the difference is the
/// whole point.
public struct TokenCount: Equatable, Sendable {

    public enum Source: String, Equatable, Sendable {
        /// The backend counted them, with the tokenizer and the chat template
        /// it will actually use on the request.
        case measured
        /// jxcode counted characters, because no backend could be asked.
        case estimated
    }

    public let tokens: Int
    public let source: Source

    public init(tokens: Int, source: Source) {
        self.tokens = tokens
        self.source = source
    }
}

/// Reads `input_tokens` out of a backend's reply.
///
/// Kept separate from the router so the shape can be asserted without a socket.
/// Anthropic and llama-server answer identically — measured against a running
/// build, `/v1/messages/count_tokens` returns `{"input_tokens":18}` — so one
/// reader serves both.
///
/// A reply that is not that shape is `nil` rather than a zero. Zero is the one
/// answer that must never be invented here: a client told it has used no
/// context believes it has unlimited room, which is worse than being told a
/// slightly wrong positive number. The same rule is why `tokens > 0` rather
/// than `tokens >= 0` — a backend that answers `0` has not measured anything a
/// caller can act on, and the estimate is the better answer.
public enum TokenCountReply {
    public static func decode(_ data: Data) -> Int? {
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
              let tokens = payload.objectValue?["input_tokens"]?.intValue,
              tokens > 0
        else { return nil }
        return tokens
    }
}

/// Remembers which backends cannot count, so the router asks each one once.
///
/// Without this the failure is paid per request rather than per backend: a
/// backend that serves `/v1/messages` but not `/v1/messages/count_tokens`
/// answers 404 every time, and Claude Code asks for a count on the way into
/// every turn. One probe, then the estimate, is the honest exchange rate.
///
/// Keyed on the normalised base URL rather than the provider id, which is the
/// same identity `ProviderStore.add` collapses on: two entries pointing at one
/// backend are one backend, and re-registering it must not re-arm a probe that
/// has already been answered.
///
/// Only the negative answer is cached. A backend that *can* count is asked
/// every time, because the count changes with every request and caching it
/// would be caching the one thing this exists to keep current.
public final class TokenCountCapability: @unchecked Sendable {

    private let lock = NSLock()
    private var unsupported: Set<String> = []

    public init() {}

    public func supports(_ provider: Provider) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !unsupported.contains(provider.normalizedBaseURL)
    }

    public func markUnsupported(_ provider: Provider) {
        lock.lock()
        defer { lock.unlock() }
        unsupported.insert(provider.normalizedBaseURL)
    }

    /// Forget every negative answer. For the tests, and for a user who has just
    /// upgraded the server behind a URL that used to refuse.
    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        unsupported.removeAll()
    }
}
