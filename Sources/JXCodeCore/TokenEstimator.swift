import Foundation

/// Estimates token counts for `/v1/messages/count_tokens`.
///
/// Why estimate rather than proxy: Claude Code calls this endpoint to decide
/// when to compact its context. Most OpenAI-compatible backends have no
/// equivalent — llama-server has `/tokenize`, vLLM and LM Studio have nothing —
/// so proxying would fail for exactly the providers this app exists to support.
///
/// The numbers are approximate on purpose. They are good enough to drive a
/// compaction decision, and the alternative (silently returning an error, or
/// zero) is worse: a zero makes the client believe it has unlimited context.
public enum TokenEstimator {

    /// Average characters per token for Latin text.
    ///
    /// Claude's tokenizer lands near 3.5–4.0 for English prose and nearer 3.0
    /// for source code. 3.6 is the blended figure, biased slightly low so the
    /// client compacts a little early rather than overflowing the window.
    private static let latinCharactersPerToken = 3.6

    /// Anthropic charges roughly one token per CJK character, sometimes a bit
    /// less for common ones. Counting them as one each is the safe direction.
    private static let cjkTokensPerCharacter = 1.0

    /// Rough cost of a single image when its dimensions are unknown.
    ///
    /// Anthropic's own figure is `(width * height) / 750`. A typical screenshot
    /// is about 1.15 megapixels, which works out to roughly this.
    private static let defaultImageTokens = 1600

    /// Fixed per-message overhead for role markers and turn separators.
    private static let perMessageOverhead = 4

    /// Overhead for one tool definition, beyond its serialised schema.
    private static let perToolOverhead = 12

    public static func estimate(_ request: AnthropicRequest) -> Int {
        var total = 0

        if let system = request.system {
            total += count(system.plainText)
        }

        for message in request.messages {
            total += perMessageOverhead
            for block in message.content.blocks {
                total += count(block: block)
            }
        }

        for tool in request.tools ?? [] {
            total += perToolOverhead
            total += count(tool.name)
            if let description = tool.description { total += count(description) }
            // The schema is JSON, which tokenizes denser than prose.
            total += Int((Double(tool.inputSchema.jsonString().count) / 3.0).rounded(.up))
        }

        return max(total, 1)
    }

    /// Token cost of one content block.
    public static func count(block: AnthropicContentBlock) -> Int {
        switch block {
        case .text(let text):
            return count(text)

        case .thinking(let thinking):
            return count(thinking)

        case .image:
            return defaultImageTokens

        case .toolUse(let id, let name, let input):
            // The assistant's own tool call, echoed back on the next turn.
            let payload = input.jsonString()
            return count(id) + count(name) + Int((Double(payload.count) / 3.0).rounded(.up))

        case .toolResult(_, let content, _):
            // Tool output is usually JSON or source, so tokenize it denser.
            let text = content.flattenedText
            return Int((Double(text.count) / 3.0).rounded(.up))

        case .unknown:
            return 0
        }
    }

    /// Token cost of a plain string, counting CJK characters individually.
    public static func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }

        let latinTokens = Double(other) / latinCharactersPerToken
        let cjkTokens = Double(cjk) * cjkTokensPerCharacter
        return Int((latinTokens + cjkTokens).rounded(.up))
    }

    /// CJK ideographs, kana, and Hangul — scripts where one character is roughly
    /// one token rather than a fraction of one.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x2EFF,   // CJK Radicals Supplement
             0x3000...0x303F,   // CJK Symbols and Punctuation
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x3130...0x318F,   // Hangul Compatibility Jamo
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul Syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF,   // Halfwidth and Fullwidth Forms
             0x20000...0x2A6DF: // CJK Unified Ideographs Extension B
            return true
        default:
            return false
        }
    }
}
