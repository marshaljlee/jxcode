package com.jxcode.android.wire

import kotlin.math.ceil

/**
 * Estimates token counts for `/v1/messages/count_tokens`.
 *
 * Why estimate rather than proxy: Claude Code calls this endpoint to decide
 * when to compact its context, and most OpenAI-compatible backends have no
 * equivalent — llama-server has `/tokenize`, vLLM and LM Studio have nothing.
 * Proxying would fail for exactly the providers this app exists to support.
 *
 * The numbers are approximate on purpose. Returning zero would be worse: the
 * client would believe it has unlimited context.
 */
object TokenEstimator {

    /** Claude's tokenizer lands near 3.5-4.0 chars/token for English prose.
     *  Biased low so the client compacts slightly early. */
    private const val LATIN_CHARACTERS_PER_TOKEN = 3.6

    /** Roughly one token per CJK character; counting one each is the safe direction. */
    private const val CJK_TOKENS_PER_CHARACTER = 1.0

    /** Anthropic's own figure is (w*h)/750; a typical screenshot is ~1.15 MP. */
    private const val DEFAULT_IMAGE_TOKENS = 1600

    private const val PER_MESSAGE_OVERHEAD = 4
    private const val PER_TOOL_OVERHEAD = 12

    fun estimate(request: AnthropicRequest): Int {
        var total = 0
        if (request.system != null) total += count(request.systemText)

        for (message in request.messages) {
            total += PER_MESSAGE_OVERHEAD
            for (block in message.blocks) total += count(block)
        }

        for (tool in request.tools.orEmpty()) {
            total += PER_TOOL_OVERHEAD
            total += count(tool.name)
            tool.description?.let { total += count(it) }
            // JSON tokenizes denser than prose.
            total += ceil(tool.inputSchema.asCompactJson().length / 3.0).toInt()
        }

        return total.coerceAtLeast(1)
    }

    fun count(block: AnthropicContentBlock): Int = when (block) {
        is AnthropicContentBlock.Text -> count(block.text)
        is AnthropicContentBlock.Thinking -> count(block.thinking)
        is AnthropicContentBlock.Image -> DEFAULT_IMAGE_TOKENS
        is AnthropicContentBlock.ToolUse ->
            count(block.id) + count(block.name) +
                ceil(block.input.asCompactJson().length / 3.0).toInt()
        is AnthropicContentBlock.ToolResult ->
            ceil(block.content.flattenedText().length / 3.0).toInt()
        is AnthropicContentBlock.Unknown -> 0
    }

    fun count(text: String): Int {
        if (text.isEmpty()) return 0
        var cjk = 0
        var other = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            if (isCJK(cp)) cjk++ else other++
            i += Character.charCount(cp)
        }
        return ceil(other / LATIN_CHARACTERS_PER_TOKEN + cjk * CJK_TOKENS_PER_CHARACTER).toInt()
    }

    private fun isCJK(cp: Int): Boolean = cp in 0x1100..0x11FF ||
        cp in 0x2E80..0x2EFF || cp in 0x3000..0x303F || cp in 0x3040..0x309F ||
        cp in 0x30A0..0x30FF || cp in 0x3130..0x318F || cp in 0x3400..0x4DBF ||
        cp in 0x4E00..0x9FFF || cp in 0xAC00..0xD7AF || cp in 0xF900..0xFAFF ||
        cp in 0xFF00..0xFFEF || cp in 0x20000..0x2A6DF
}
