package com.jxcode.android.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Anthropic Messages API shapes, mirroring `AnthropicWire.swift`.
 *
 * Two deliberate leniencies, both learned the hard way on the macOS build:
 * unknown content-block types decode to [AnthropicContentBlock.Unknown]
 * instead of throwing, and unknown top-level keys are ignored. A router that
 * rejects what it does not understand breaks the day a client adds a field.
 */

val WireJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = false
    isLenient = true
}

// MARK: - Request

@Serializable
data class AnthropicRequest(
    val model: String = "",
    @SerialName("max_tokens") val maxTokens: Int = 4096,
    val system: JsonElement? = null,
    val messages: List<AnthropicMessage> = emptyList(),
    val tools: List<AnthropicTool>? = null,
    @SerialName("tool_choice") val toolChoice: AnthropicToolChoice? = null,
    val temperature: Double? = null,
    @SerialName("top_p") val topP: Double? = null,
    @SerialName("stop_sequences") val stopSequences: List<String>? = null,
    val stream: Boolean? = null,
    val metadata: JsonObject? = null,
    val thinking: AnthropicThinking? = null
) {
    /** `system` is a bare string or an array of blocks; both are in use. */
    val systemText: String
        get() = when (val s = system) {
            null -> ""
            is JsonPrimitive -> s.content
            else -> s.jsonArray.mapNotNull { it.toBlockOrNull()?.textValue }.joinToString("\n\n")
        }

    val systemIsBlocks: Boolean get() = system is JsonArray
}

@Serializable
data class AnthropicMessage(
    val role: String = "user",
    val content: JsonElement? = null
) {
    val blocks: List<AnthropicContentBlock>
        get() = when (val c = content) {
            null -> emptyList()
            is JsonPrimitive -> listOf(AnthropicContentBlock.Text(c.content))
            else -> c.jsonArray.map { it.toBlock() }
        }

    val plainText: String
        get() = blocks.mapNotNull { it.textValue }.joinToString("")

    companion object {
        fun text(role: String, value: String) =
            AnthropicMessage(role, JsonPrimitive(value))

        fun blocks(role: String, value: List<AnthropicContentBlock>) =
            AnthropicMessage(role, buildJsonArray { value.forEach { add(it.toJson()) } })
    }
}

@Serializable(with = AnthropicContentBlock.AsJson::class)
sealed class AnthropicContentBlock {

    data class Text(val text: String) : AnthropicContentBlock()
    data class Image(val mediaType: String, val base64: String) : AnthropicContentBlock()
    data class ToolUse(val id: String, val name: String, val input: JsonElement = JsonObject(emptyMap())) :
        AnthropicContentBlock()

    data class ToolResult(
        val toolUseId: String,
        val content: JsonElement = JsonNull,
        val isError: Boolean = false
    ) : AnthropicContentBlock()

    data class Thinking(val thinking: String) : AnthropicContentBlock()
    data class Unknown(val type: String) : AnthropicContentBlock()

    val textValue: String?
        get() = when (this) {
            is Text -> text
            is Thinking -> thinking
            else -> null
        }

    val isToolUse: Boolean get() = this is ToolUse

    fun toJson(): JsonElement = buildJsonObject {
        when (val b = this@AnthropicContentBlock) {
            is Text -> {
                put("type", "text"); put("text", b.text)
            }
            is Image -> {
                put("type", "image")
                putJsonObject("source") {
                    put("type", "base64")
                    put("media_type", b.mediaType)
                    put("data", b.base64)
                }
            }
            is ToolUse -> {
                put("type", "tool_use")
                put("id", b.id)
                put("name", b.name)
                put("input", b.input)
            }
            is ToolResult -> {
                put("type", "tool_result")
                put("tool_use_id", b.toolUseId)
                put("content", b.content)
                if (b.isError) put("is_error", true)
            }
            is Thinking -> {
                put("type", "thinking"); put("thinking", b.thinking)
            }
            is Unknown -> put("type", b.type)
        }
    }

    /**
     * Hand-written because the sealed hierarchy must survive unknown `type`
     * values: the default polymorphic decoder throws on them, and one unknown
     * block would otherwise fail the whole request.
     */
    object AsJson : KSerializer<AnthropicContentBlock> {
        override val descriptor: SerialDescriptor =
            kotlinx.serialization.json.JsonElement.serializer().descriptor

        override fun deserialize(decoder: Decoder): AnthropicContentBlock =
            decoder.decodeSerializableValue(kotlinx.serialization.json.JsonElement.serializer()).toBlock()

        override fun serialize(encoder: Encoder, value: AnthropicContentBlock) =
            encoder.encodeSerializableValue(
                kotlinx.serialization.json.JsonElement.serializer(), value.toJson()
            )
    }

    companion object {
        fun toolUse(id: String, name: String, input: JsonElement) = ToolUse(id, name, input)
    }
}

/** Lenient: an unrecognised or malformed block becomes [Unknown], never an error. */
fun JsonElement.toBlock(): AnthropicContentBlock =
    toBlockOrNull() ?: AnthropicContentBlock.Unknown("unknown")

fun JsonElement.toBlockOrNull(): AnthropicContentBlock? {
    val obj = this as? JsonObject ?: return AnthropicContentBlock.Unknown("unknown")
    val type = obj["type"]?.jsonPrimitive?.content ?: "unknown"
    return when (type) {
        "text" -> AnthropicContentBlock.Text(obj["text"]?.jsonPrimitive?.content ?: "")
        "image" -> {
            val src = obj["source"]?.jsonObject
            AnthropicContentBlock.Image(
                mediaType = src?.get("media_type")?.jsonPrimitive?.content ?: "image/png",
                base64 = src?.get("data")?.jsonPrimitive?.content ?: ""
            )
        }
        "tool_use" -> AnthropicContentBlock.ToolUse(
            id = obj["id"]?.jsonPrimitive?.content ?: "",
            name = obj["name"]?.jsonPrimitive?.content ?: "",
            input = obj["input"] ?: JsonObject(emptyMap())
        )
        "tool_result" -> AnthropicContentBlock.ToolResult(
            toolUseId = obj["tool_use_id"]?.jsonPrimitive?.content ?: "",
            content = obj["content"] ?: JsonNull,
            isError = obj["is_error"]?.jsonPrimitive?.content?.toBoolean() ?: false
        )
        "thinking" -> AnthropicContentBlock.Thinking(obj["thinking"]?.jsonPrimitive?.content ?: "")
        else -> AnthropicContentBlock.Unknown(type)
    }
}

@Serializable
data class AnthropicTool(
    val name: String,
    val description: String? = null,
    @SerialName("input_schema") val inputSchema: JsonElement = JsonObject(emptyMap())
)

@Serializable
data class AnthropicToolChoice(
    val type: String,
    val name: String? = null,
    @SerialName("disable_parallel_tool_use") val disableParallelToolUse: Boolean? = null
)

@Serializable
data class AnthropicThinking(
    val type: String,
    @SerialName("budget_tokens") val budgetTokens: Int? = null
)

// MARK: - Response

@Serializable
data class AnthropicResponse(
    val id: String,
    val type: String = "message",
    val role: String = "assistant",
    val model: String,
    val content: List<AnthropicContentBlock>,
    @SerialName("stop_reason") val stopReason: String? = null,
    @SerialName("stop_sequence") val stopSequence: String? = null,
    val usage: AnthropicUsage
)

@Serializable
data class AnthropicUsage(
    @SerialName("input_tokens") val inputTokens: Int = 0,
    @SerialName("output_tokens") val outputTokens: Int = 0
)

@Serializable
data class AnthropicCountTokensResponse(
    @SerialName("input_tokens") val inputTokens: Int
)

/** Claude Code reads `error.message` to decide whether to retry. */
@Serializable
data class AnthropicErrorEnvelope(
    val type: String = "error",
    val error: Body
) {
    @Serializable
    data class Body(val type: String, val message: String)

    companion object {
        fun apiError(message: String) = AnthropicErrorEnvelope(error = Body("api_error", message))
    }
}

/**
 * Frames Anthropic streaming events: `event: <name>\ndata: <json>\n\n`.
 *
 * Generated in one place because a missing blank line makes the client buffer
 * forever, which is indistinguishable from a stalled model.
 */
object AnthropicSSE {

    fun frame(event: String, payload: JsonElement): String =
        "event: $event\ndata: ${payload.asCompactJson()}\n\n"

    fun messageStart(messageID: String, model: String, inputTokens: Int): String =
        frame("message_start", buildJsonObject {
            put("type", "message_start")
            putJsonObject("message") {
                put("id", messageID)
                put("type", "message")
                put("role", "assistant")
                put("model", model)
                putJsonArray("content") { }
                put("stop_reason", JsonNull)
                put("stop_sequence", JsonNull)
                putJsonObject("usage") {
                    put("input_tokens", inputTokens)
                    put("output_tokens", 0)
                }
            }
        })

    fun contentBlockStart(index: Int, block: JsonElement): String =
        frame("content_block_start", buildJsonObject {
            put("type", "content_block_start")
            put("index", index)
            put("content_block", block)
        })

    fun textBlockStart(index: Int) = contentBlockStart(index, buildJsonObject {
        put("type", "text"); put("text", "")
    })

    fun thinkingBlockStart(index: Int) = contentBlockStart(index, buildJsonObject {
        put("type", "thinking"); put("thinking", "")
    })

    fun toolBlockStart(index: Int, id: String, name: String) =
        contentBlockStart(index, buildJsonObject {
            put("type", "tool_use")
            put("id", id)
            put("name", name)
            putJsonObject("input") { }
        })

    fun textDelta(index: Int, text: String) = frame("content_block_delta", buildJsonObject {
        put("type", "content_block_delta")
        put("index", index)
        putJsonObject("delta") { put("type", "text_delta"); put("text", text) }
    })

    fun thinkingDelta(index: Int, thinking: String) =
        frame("content_block_delta", buildJsonObject {
            put("type", "content_block_delta")
            put("index", index)
            putJsonObject("delta") { put("type", "thinking_delta"); put("thinking", thinking) }
        })

    fun inputJSONDelta(index: Int, partialJSON: String) =
        frame("content_block_delta", buildJsonObject {
            put("type", "content_block_delta")
            put("index", index)
            putJsonObject("delta") { put("type", "input_json_delta"); put("partial_json", partialJSON) }
        })

    fun contentBlockStop(index: Int) = frame("content_block_stop", buildJsonObject {
        put("type", "content_block_stop"); put("index", index)
    })

    fun messageDelta(stopReason: String, outputTokens: Int, inputTokens: Int? = null) =
        frame("message_delta", buildJsonObject {
            put("type", "message_delta")
            putJsonObject("delta") {
                put("stop_reason", stopReason)
                put("stop_sequence", JsonNull)
            }
            putJsonObject("usage") {
                put("output_tokens", outputTokens)
                if (inputTokens != null) put("input_tokens", inputTokens)
            }
        })

    fun messageStop() = frame("message_stop", buildJsonObject { put("type", "message_stop") })

    fun ping() = frame("ping", buildJsonObject { put("type", "ping") })
}

/**
 * Compact JSON for a subtree.
 *
 * `JsonElement.toString()` already emits valid compact JSON, which avoids
 * re-entering the serializer for values that were only ever passed through.
 */
internal fun JsonElement.asCompactJson(): String = toString()
