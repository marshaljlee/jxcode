package com.jxcode.android.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * OpenAI Chat Completions shapes, mirroring `OpenAIWire.swift`.
 *
 * This is the de-facto interchange format — llama-server, vLLM, LM Studio,
 * Ollama's compatibility layer, OpenRouter and most gateways speak it — so
 * every non-Anthropic backend is reached by translating into this shape.
 */

@Serializable
data class OpenAIChatRequest(
    val model: String,
    val messages: List<OpenAIMessage>,
    @SerialName("max_tokens") val maxTokens: Int? = null,
    val temperature: Double? = null,
    @SerialName("top_p") val topP: Double? = null,
    val stop: List<String>? = null,
    val tools: List<OpenAITool>? = null,
    @SerialName("tool_choice") val toolChoice: JsonElement? = null,
    @SerialName("parallel_tool_calls") val parallelToolCalls: Boolean? = null,
    val stream: Boolean? = null,
    @SerialName("stream_options") val streamOptions: OpenAIStreamOptions? = null
)

@Serializable
data class OpenAIMessage(
    // Streaming deltas carry `role` only on the first chunk. A required field
    // would throw on later chunks, and a skipped chunk truncates the stream to
    // one token — so this must default rather than fail.
    val role: String = "assistant",
    val content: JsonElement? = null,
    @SerialName("tool_calls") val toolCalls: List<OpenAIToolCall>? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    val name: String? = null,
    @SerialName("reasoning_content") val reasoningContent: String? = null,
    val reasoning: String? = null
) {
    /** Whichever reasoning field the backend populated. */
    val anyReasoning: String? get() = reasoningContent ?: reasoning

    /** Flattens `"text"` and `[{type:text,text:...}]` to plain text. */
    val plainText: String
        get() = when (val c = content) {
            null -> ""
            is JsonPrimitive -> if (c.isString) c.content else ""
            else -> c.jsonArray.mapNotNull {
                it.jsonObject["text"]?.jsonPrimitive?.content
            }.joinToString("")
        }

    companion object {
        fun text(role: String, value: String) = OpenAIMessage(role = role, content = JsonPrimitive(value))
    }
}

@Serializable
data class OpenAIStreamOptions(
    @SerialName("include_usage") val includeUsage: Boolean = true
)

@Serializable
data class OpenAITool(
    val type: String = "function",
    val function: OpenAIToolFunction
)

@Serializable
data class OpenAIToolFunction(
    val name: String,
    val description: String? = null,
    val parameters: JsonElement? = null
)

@Serializable
data class OpenAIToolCall(
    val index: Int = 0,
    val id: String? = null,
    val type: String? = "function",
    val function: OpenAICalledFunction? = null
)

@Serializable
data class OpenAICalledFunction(
    val name: String? = null,
    val arguments: String? = null
)

@Serializable
data class OpenAIUsage(
    @SerialName("prompt_tokens") val promptTokens: Int? = null,
    @SerialName("completion_tokens") val completionTokens: Int? = null,
    @SerialName("total_tokens") val totalTokens: Int? = null
)

@Serializable
data class OpenAIChoice(
    val index: Int = 0,
    val delta: OpenAIMessage? = null,
    val message: OpenAIMessage? = null,
    @SerialName("finish_reason") val finishReason: String? = null
) {
    /** `delta` while streaming, `message` otherwise. */
    val payload: OpenAIMessage? get() = delta ?: message
}

@Serializable
data class OpenAIChatResponse(
    val id: String? = null,
    val model: String? = null,
    val choices: List<OpenAIChoice> = emptyList(),
    val usage: OpenAIUsage? = null,
    val error: JsonElement? = null
) {
    val first: OpenAIChoice? get() = choices.firstOrNull()

    val errorMessage: String?
        get() = (error as? JsonObject)?.get("message")?.jsonPrimitive?.content
}

@Serializable
data class OpenAIModel(
    val id: String,
    val `object`: String? = "model",
    val created: Long? = null
)

@Serializable
data class OpenAIModelList(
    val `object`: String? = "list",
    val data: List<OpenAIModel> = emptyList()
)

object OpenAIToolChoice {
    fun auto() = JsonPrimitive("auto")
    fun none() = JsonPrimitive("none")
    fun named(name: String) = buildJsonObject {
        put("type", "function")
        putJsonObject("function") { put("name", name) }
    }
}
