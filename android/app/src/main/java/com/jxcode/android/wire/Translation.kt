package com.jxcode.android.wire

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * A translated request plus a record of what could not be carried across.
 *
 * The notes are surfaced in the providers pane and the router log. Silent loss
 * is what makes a translation layer maddening to debug: "why did my model stop
 * using tools" is almost always a field that vanished here.
 */
data class TranslationResult(
    val request: OpenAIChatRequest,
    val notes: List<String> = emptyList()
)

/**
 * Anthropic Messages <-> OpenAI Chat Completions.
 *
 * The two formats disagree on four things that matter in practice:
 *
 *  1. **Tool results live in different places.** Anthropic puts `tool_result`
 *     blocks inside a `user` message; OpenAI requires separate `tool` messages
 *     with a matching `tool_call_id`, and they must come first.
 *  2. **Tool arguments are an object on one side and a JSON *string* on the
 *     other.**
 *  3. **`system` is a message on one side and a top-level field on the other.**
 *  4. **Stop reasons and streaming event names differ entirely.**
 */
object Translation {

    // MARK: Anthropic -> OpenAI

    fun request(source: AnthropicRequest): TranslationResult {
        val notes = mutableListOf<String>()
        val messages = mutableListOf<OpenAIMessage>()

        val systemText = source.systemText
        if (systemText.isNotEmpty()) {
            messages.add(OpenAIMessage.text("system", systemText))
        }
        if (source.systemIsBlocks) {
            notes.add("system: block metadata (e.g. cache_control) dropped")
        }

        var droppedThinking = 0
        var unknownBlocks = 0
        var splitToolResults = 0

        for (message in source.messages) {
            val blocks = message.blocks

            if (message.role == "assistant") {
                var text = ""
                val toolCalls = mutableListOf<OpenAIToolCall>()

                for (block in blocks) {
                    when (block) {
                        is AnthropicContentBlock.Text -> text += block.text
                        is AnthropicContentBlock.ToolUse -> toolCalls.add(
                            OpenAIToolCall(
                                index = toolCalls.size,
                                id = block.id,
                                type = "function",
                                function = OpenAICalledFunction(
                                    name = block.name,
                                    arguments = block.input.asCompactJson()
                                )
                            )
                        )
                        is AnthropicContentBlock.Thinking -> droppedThinking++
                        else -> unknownBlocks++ // image/toolResult/unknown are illegal here
                    }
                }

                // An empty assistant turn upsets strict backends.
                if (text.isEmpty() && toolCalls.isEmpty()) continue

                messages.add(
                    OpenAIMessage(
                        role = "assistant",
                        content = if (text.isEmpty()) null else JsonPrimitive(text),
                        toolCalls = toolCalls.ifEmpty { null }
                    )
                )
            } else {
                val toolMessages = mutableListOf<OpenAIMessage>()
                val parts = mutableListOf<JsonElement>()
                var plainText = ""
                var hasImages = false

                for (block in blocks) {
                    when (block) {
                        is AnthropicContentBlock.Text -> {
                            plainText += block.text
                            parts.add(buildJsonObject {
                                put("type", "text"); put("text", block.text)
                            })
                        }
                        is AnthropicContentBlock.Image -> {
                            hasImages = true
                            parts.add(buildJsonObject {
                                put("type", "image_url")
                                putJsonObject("image_url") {
                                    put("url", "data:${block.mediaType};base64,${block.base64}")
                                }
                            })
                        }
                        is AnthropicContentBlock.ToolResult -> {
                            val text = block.content.flattenedText()
                            toolMessages.add(
                                OpenAIMessage(
                                    role = "tool",
                                    content = JsonPrimitive(
                                        if (text.isEmpty() && block.isError) "Tool failed with no output." else text
                                    ),
                                    toolCallId = block.toolUseId
                                )
                            )
                            splitToolResults++
                        }
                        is AnthropicContentBlock.Thinking -> droppedThinking++
                        else -> unknownBlocks++
                    }
                }

                messages.addAll(toolMessages)

                if (plainText.isNotEmpty() || hasImages) {
                    messages.add(
                        OpenAIMessage(
                            role = "user",
                            content = if (hasImages) JsonArray(parts) else JsonPrimitive(plainText)
                        )
                    )
                }
            }
        }

        // Most backends reject a conversation that never addresses the model.
        // An assistant-only conversation reaches here when user turns were empty.
        if (messages.none { it.role == "user" }) {
            messages.add(OpenAIMessage.text("user", "Hello"))
            notes.add("no user content found; substituted a placeholder turn")
        }

        val tools = source.tools?.takeIf { it.isNotEmpty() }?.map { tool ->
            OpenAITool(
                function = OpenAIToolFunction(
                    name = tool.name,
                    description = tool.description,
                    parameters = tool.inputSchema
                )
            )
        }

        val request = OpenAIChatRequest(
            model = source.model,
            messages = messages,
            maxTokens = source.maxTokens,
            temperature = source.temperature,
            topP = source.topP,
            stop = source.stopSequences,
            tools = tools,
            toolChoice = toolChoice(source.toolChoice),
            parallelToolCalls = parallelToolCalls(source.toolChoice),
            stream = source.stream,
            // Without this, OpenAI-compatible servers omit the final usage chunk
            // and the client's token accounting stays at zero.
            streamOptions = if (source.stream == true) OpenAIStreamOptions(includeUsage = true) else null
        )

        if (droppedThinking > 0) {
            notes.add("$droppedThinking thinking block(s) dropped — upstream has no equivalent")
        }
        if (unknownBlocks > 0) notes.add("$unknownBlocks unsupported block(s) dropped")
        if (splitToolResults > 0) {
            notes.add("$splitToolResults tool_result block(s) split into tool messages")
        }
        if (source.thinking != null) {
            notes.add("thinking parameter dropped — enable reasoning in the model or its template instead")
        }
        if (source.metadata != null) notes.add("metadata dropped")

        return TranslationResult(request, notes)
    }

    /** Anthropic's four modes collapse onto OpenAI's three, plus the object form. */
    fun toolChoice(choice: AnthropicToolChoice?): JsonElement? = when (choice?.type) {
        null -> null
        "auto" -> JsonPrimitive("auto")
        "any" -> JsonPrimitive("required")
        "none" -> JsonPrimitive("none")
        "tool" -> choice.name?.let { OpenAIToolChoice.named(it) } ?: JsonPrimitive("required")
        else -> JsonPrimitive("auto")
    }

    fun parallelToolCalls(choice: AnthropicToolChoice?): Boolean? =
        choice?.disableParallelToolUse?.let { !it }

    // MARK: OpenAI -> Anthropic

    fun response(
        source: OpenAIChatResponse,
        requestedModel: String,
        inputTokens: Int? = null
    ): AnthropicResponse {
        val choice = source.first
        val message = choice?.payload

        val content = mutableListOf<AnthropicContentBlock>()

        val reasoning = message?.anyReasoning
        if (!reasoning.isNullOrEmpty()) content.add(AnthropicContentBlock.Thinking(reasoning))

        val text = message?.plainText ?: ""
        if (text.isNotEmpty()) content.add(AnthropicContentBlock.Text(text))

        for (call in message?.toolCalls.orEmpty()) {
            content.add(
                AnthropicContentBlock.ToolUse(
                    id = call.id ?: newToolUseId(),
                    name = call.function?.name ?: "",
                    input = Json.parseToJsonElementOrNull(call.function?.arguments ?: "{}")
                        ?: JsonObject(emptyMap())
                )
            )
        }

        // Anthropic clients expect at least one block; an empty array can make
        // them render nothing at all, which looks like a hang.
        if (content.isEmpty()) content.add(AnthropicContentBlock.Text(""))

        val promptTokens = source.usage?.promptTokens ?: inputTokens ?: 0
        val completionTokens = source.usage?.completionTokens ?: TokenEstimator.count(text)

        return AnthropicResponse(
            id = source.id ?: newMessageId(),
            // The name the client asked for, not the substituted one: Claude
            // Code keys its context-window table off it.
            model = requestedModel,
            content = content,
            stopReason = stopReason(choice?.finishReason, content.any { it.isToolUse }),
            usage = AnthropicUsage(inputTokens = promptTokens, outputTokens = completionTokens)
        )
    }

    fun stopReason(finishReason: String?, hasToolUse: Boolean): String {
        // Trust the content over the label: several backends report `stop` even
        // when the turn ended in a tool call, and the agent loop only continues
        // when it sees `tool_use`.
        if (hasToolUse) return "tool_use"
        return when (finishReason) {
            "stop" -> "end_turn"
            "length" -> "max_tokens"
            "tool_calls", "function_call" -> "tool_use"
            "content_filter" -> "end_turn"
            null -> "end_turn"
            else -> "end_turn"
        }
    }

    fun newMessageId(): String = "msg_" + randomHex(24)
    fun newToolUseId(): String = "toolu_" + randomHex(24)

    private fun randomHex(length: Int): String {
        val chars = "0123456789abcdef"
        return buildString(length) { repeat(length) { append(chars.random()) } }
    }

    /**
     * Synthesises Anthropic's block boundaries from OpenAI's flat delta run.
     *
     * The block index matters: the client keys its rendering off it, and a
     * re-used or out-of-order index makes text appear in the wrong place.
     *
     * **Call [finalize] when the upstream stream ends** — termination is
     * deliberately not emitted on `finish_reason`, because with
     * `include_usage` the real token counts arrive in a later chunk with an
     * empty `choices` array.
     */
    class StreamTranslator(
        private val messageId: String = newMessageId(),
        private val model: String,
        private val inputTokens: Int
    ) {
        private sealed class OpenBlock { abstract val index: Int
            data class Text(override val index: Int) : OpenBlock()
            data class Thinking(override val index: Int) : OpenBlock()
            data class Tool(override val index: Int) : OpenBlock()
        }

        private var started = false
        private var finalized = false
        private var nextIndex = 0
        private var open: OpenBlock? = null

        /** Upstream `tool_calls[].index` -> the Anthropic block index assigned. */
        private val toolBlockIndex = mutableMapOf<Int, Int>()
        private var sawToolUse = false
        private var outputCharacters = 0
        private var pendingStopReason: String? = null
        private var reportedUsage: OpenAIUsage? = null

        val reportedModel: String get() = model

        fun consume(chunk: OpenAIChatResponse): List<String> {
            if (finalized) return emptyList()

            val out = mutableListOf<String>()
            val choice = chunk.first

            if (!started) {
                started = true
                out.add(
                    AnthropicSSE.messageStart(
                        messageID = messageId,
                        model = model,
                        inputTokens = chunk.usage?.promptTokens ?: inputTokens
                    )
                )
            }

            if (chunk.usage != null) reportedUsage = chunk.usage

            val payload = choice?.payload

            // Reasoning first: a model that thinks before answering sends it
            // ahead of any content, and block order should reflect that.
            val reasoning = payload?.anyReasoning
            if (!reasoning.isNullOrEmpty()) out.addAll(appendThinking(reasoning))

            val text = payload?.plainText ?: ""
            if (text.isNotEmpty()) out.addAll(appendText(text))

            for (call in payload?.toolCalls.orEmpty()) out.addAll(appendToolCall(call))

            // No more deltas are coming for this choice, so the open block can
            // close — but the message stays open until the usage trailer lands.
            if (choice?.finishReason != null) {
                open?.let { out.add(AnthropicSSE.contentBlockStop(it.index)) }
                open = null
                pendingStopReason = choice.finishReason
            }

            return out
        }

        fun finalize(): List<String> {
            if (!started || finalized) return emptyList()
            finalized = true

            val out = mutableListOf<String>()
            open?.let { out.add(AnthropicSSE.contentBlockStop(it.index)) }
            open = null

            val outputTokens = reportedUsage?.completionTokens ?: (outputCharacters / 4).coerceAtLeast(1)

            out.add(
                AnthropicSSE.messageDelta(
                    stopReason = stopReason(pendingStopReason, sawToolUse),
                    outputTokens = outputTokens,
                    inputTokens = reportedUsage?.promptTokens
                )
            )
            out.add(AnthropicSSE.messageStop())
            return out
        }

        private fun appendThinking(text: String): List<String> {
            val out = mutableListOf<String>()
            if (open !is OpenBlock.Thinking) {
                open?.let { out.add(AnthropicSSE.contentBlockStop(it.index)) }
                val index = nextIndex++
                open = OpenBlock.Thinking(index)
                out.add(AnthropicSSE.thinkingBlockStart(index))
            }
            val block = open ?: return out
            outputCharacters += text.length
            out.add(AnthropicSSE.thinkingDelta(block.index, text))
            return out
        }

        private fun appendText(text: String): List<String> {
            val out = mutableListOf<String>()
            if (open !is OpenBlock.Text) {
                open?.let { out.add(AnthropicSSE.contentBlockStop(it.index)) }
                val index = nextIndex++
                open = OpenBlock.Text(index)
                out.add(AnthropicSSE.textBlockStart(index))
            }
            val block = open ?: return out
            outputCharacters += text.length
            out.add(AnthropicSSE.textDelta(block.index, text))
            return out
        }

        private fun appendToolCall(call: OpenAIToolCall): List<String> {
            val out = mutableListOf<String>()
            val callIndex = call.index

            toolBlockIndex[callIndex]?.let { blockIndex ->
                val fragment = call.function?.arguments
                if (!fragment.isNullOrEmpty()) {
                    out.add(AnthropicSSE.inputJSONDelta(blockIndex, fragment))
                }
                return out
            }

            val fragment = call.function?.arguments
            val isNewCall = call.id != null || call.function?.name != null
            if (!isNewCall) {
                // Argument fragment with no start seen: attribute it to the most
                // recent tool block rather than dropping it, which would
                // corrupt the arguments.
                toolBlockIndex.values.maxOrNull()?.let { last ->
                    if (!fragment.isNullOrEmpty()) out.add(AnthropicSSE.inputJSONDelta(last, fragment))
                }
                return out
            }

            open?.let { out.add(AnthropicSSE.contentBlockStop(it.index)) }
            val index = nextIndex++
            open = OpenBlock.Tool(index)
            toolBlockIndex[callIndex] = index
            sawToolUse = true

            out.add(
                AnthropicSSE.toolBlockStart(
                    index = index,
                    id = call.id ?: newToolUseId(),
                    name = call.function?.name ?: ""
                )
            )
            if (!fragment.isNullOrEmpty()) out.add(AnthropicSSE.inputJSONDelta(index, fragment))
            return out
        }
    }

    // MARK: Reverse direction

    /** Anthropic response -> OpenAI, for an OpenAI client on an Anthropic backend. */
    fun openAIResponse(from: AnthropicResponse): OpenAIChatResponse {
        var text = ""
        var reasoning: String? = null
        val toolCalls = mutableListOf<OpenAIToolCall>()

        for (block in from.content) {
            when (block) {
                is AnthropicContentBlock.Text -> text += block.text
                is AnthropicContentBlock.Thinking -> reasoning = (reasoning ?: "") + block.thinking
                is AnthropicContentBlock.ToolUse -> toolCalls.add(
                    OpenAIToolCall(
                        index = toolCalls.size,
                        id = block.id,
                        type = "function",
                        function = OpenAICalledFunction(
                            name = block.name,
                            arguments = block.input.asCompactJson()
                        )
                    )
                )
                else -> Unit
            }
        }

        val message = OpenAIMessage(
            role = "assistant",
            content = JsonPrimitive(text),
            toolCalls = if (toolCalls.isEmpty()) null else toolCalls,
            reasoningContent = reasoning
        )

        return OpenAIChatResponse(
            id = from.id,
            model = from.model,
            choices = listOf(
                OpenAIChoice(index = 0, message = message, finishReason = when (from.stopReason) {
                    "tool_use" -> "tool_calls"
                    "max_tokens" -> "length"
                    else -> "stop"
                })
            ),
            usage = OpenAIUsage(
                promptTokens = from.usage.inputTokens,
                completionTokens = from.usage.outputTokens
            )
        )
    }

    /** OpenAI request -> Anthropic. Tool messages become `tool_result` blocks. */
    fun anthropicRequest(from: OpenAIChatRequest): AnthropicRequest {
        var system: String? = null
        val messages = mutableListOf<AnthropicMessage>()
        var pendingToolResults = mutableListOf<AnthropicContentBlock>()
        var toolNames = mutableMapOf<String, String>()

        fun flushToolResults() {
            if (pendingToolResults.isNotEmpty()) {
                messages.add(AnthropicMessage.blocks("user", pendingToolResults.toList()))
                pendingToolResults = mutableListOf()
            }
        }

        for (message in from.messages) {
            when (message.role) {
                "system" -> system = (system?.let { "$it\n\n" } ?: "") + message.plainText
                "tool" -> {
                    val id = message.toolCallId ?: ""
                    pendingToolResults.add(
                        AnthropicContentBlock.ToolResult(
                            toolUseId = id,
                            content = JsonPrimitive(message.plainText)
                        )
                    )
                }
                "assistant" -> {
                    flushToolResults()
                    val blocks = mutableListOf<AnthropicContentBlock>()
                    val reasoning = message.anyReasoning
                    if (!reasoning.isNullOrEmpty()) blocks.add(AnthropicContentBlock.Thinking(reasoning))
                    val text = message.plainText
                    if (text.isNotEmpty()) blocks.add(AnthropicContentBlock.Text(text))
                    for (call in message.toolCalls.orEmpty()) {
                        val name = call.function?.name ?: ""
                        val id = call.id ?: newToolUseId()
                        toolNames[id] = name
                        blocks.add(
                            AnthropicContentBlock.ToolUse(
                                id = id,
                                name = name,
                                input = Json.parseToJsonElementOrNull(call.function?.arguments ?: "{}")
                                    ?: JsonObject(emptyMap())
                            )
                        )
                    }
                    if (blocks.isNotEmpty()) messages.add(AnthropicMessage.blocks("assistant", blocks))
                }
                else -> {
                    flushToolResults()
                    messages.add(AnthropicMessage.text("user", message.plainText))
                }
            }
        }
        flushToolResults()

        val tools = from.tools?.map {
            AnthropicTool(
                name = it.function.name,
                description = it.function.description,
                inputSchema = it.function.parameters ?: JsonObject(emptyMap())
            )
        }

        return AnthropicRequest(
            model = from.model,
            maxTokens = from.maxTokens ?: 4096,
            system = system?.let { JsonPrimitive(it) },
            messages = messages,
            tools = tools,
            toolChoice = anthropicToolChoice(from.toolChoice),
            temperature = from.temperature,
            topP = from.topP,
            stopSequences = from.stop,
            stream = from.stream
        )
    }

    fun anthropicToolChoice(choice: JsonElement?): AnthropicToolChoice? {
        when (choice) {
            null -> return null
            is JsonPrimitive -> return when (choice.contentOrNull) {
                "auto" -> AnthropicToolChoice("auto")
                "required", "any" -> AnthropicToolChoice("any")
                "none" -> AnthropicToolChoice("none")
                else -> AnthropicToolChoice("auto")
            }
            is JsonObject -> {
                val type = choice["type"]?.jsonPrimitive?.contentOrNull ?: return AnthropicToolChoice("auto")
                val name = choice["function"]?.jsonObject?.get("name")?.jsonPrimitive?.contentOrNull
                return AnthropicToolChoice(type = if (type == "function") "tool" else type, name = name)
            }
            else -> return null
        }
    }

    /** `data:<mediaType>;base64,<data>` -> its two halves. */
    fun parseDataURI(uri: String): Pair<String, String>? {
        if (!uri.startsWith("data:")) return null
        val comma = uri.indexOf(',')
        if (comma < 0) return null
        val meta = uri.substring(5, comma)
        val mediaType = meta.substringBefore(';')
        val data = uri.substring(comma + 1)
        return mediaType to data
    }
}

/** Text carried by a `tool_result`'s JSON payload, whatever its shape. */
fun JsonElement.flattenedText(): String = when (this) {
    JsonNull -> ""
    is JsonPrimitive -> if (isString) content else toString()
    is JsonArray -> joinToString("\n") { element ->
        (element as? JsonObject)?.get("text")?.jsonPrimitive?.contentOrNull ?: ""
    }
    is JsonObject -> this["text"]?.jsonPrimitive?.contentOrNull ?: toString()
}

fun Json.parseToJsonElementOrNull(text: String): JsonElement? =
    try { parseToJsonElement(text) } catch (_: Throwable) { null }
