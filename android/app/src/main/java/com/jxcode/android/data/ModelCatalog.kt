package com.jxcode.android.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL

/**
 * Fetches a backend's model list.
 *
 * Four envelope shapes are handled because in practice they all occur:
 *
 *   {"data":[{"id":"..."}]}   OpenAI, vLLM, llama-server
 *   {"data":["..."]}          several gateways
 *   ["..."]                   Ollama's non-standard route
 *   {"models":[...]}          llama-server's older build
 *
 * A backend that answers something else is reported with its raw shape rather
 * than silently yielding an empty list, which the UI would render as "this
 * provider has no models".
 */
object ModelCatalog {

    private const val TIMEOUT_MS = 20_000
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    data class Fetch(
        val ids: List<String>,
        val note: String? = null,
        val error: String? = null
    ) {
        val isEmpty get() = ids.isEmpty()
    }

    fun modelsURL(baseURL: String): String {
        val base = baseURL.trim().trimEnd('/')
        return when {
            base.endsWith("/models") -> base
            base.endsWith("/v1") -> "$base/models"
            base.endsWith("/v1/") -> "${base}models"
            else -> "$base/v1/models"
        }
    }

    suspend fun fetch(provider: Provider, apiKey: String?): Fetch =
        withContext(Dispatchers.IO) {
            val url = modelsURL(provider.normalizedBaseURL)
            var connection: HttpURLConnection? = null
            try {
                connection = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    setRequestProperty("Accept", "application/json")
                    if (!apiKey.isNullOrBlank()) {
                        // Anthropic's own header and the OpenAI one: sending
                        // both costs nothing and covers either shape.
                        setRequestProperty("x-api-key", apiKey)
                        setRequestProperty("Authorization", "Bearer $apiKey")
                    }
                }
                val status = connection.responseCode
                if (status !in 200..299) {
                    return@withContext Fetch(emptyList(), error = "HTTP $status from $url")
                }
                val text = connection.inputStream.bufferedReader().readText()
                val ids = parse(text)
                if (ids.isEmpty()) {
                    Fetch(emptyList(), note = "no model ids recognised in the response from $url")
                } else {
                    Fetch(ids)
                }
            } catch (e: Exception) {
                Fetch(emptyList(), error = e.message ?: e.toString())
            } finally {
                connection?.disconnect()
            }
        }

    fun parse(text: String): List<String> {
        val element = try {
            json.parseToJsonElement(text)
        } catch (_: Throwable) {
            return emptyList()
        }
        return when (element) {
            is JsonArray -> element.mapNotNull { it.idOrName() }
            is JsonObject -> {
                val data = element["data"]
                if (data != null) {
                    when (data) {
                        is JsonArray -> data.mapNotNull { it.idOrName() }
                        else -> emptyList()
                    }
                } else {
                    val models = element["models"]
                    when (models) {
                        is JsonArray -> models.mapNotNull { it.idOrName() }
                        is JsonObject -> models["data"]?.let { (it as? JsonArray)?.mapNotNull { e -> e.idOrName() } }
                            ?: emptyList()
                        else -> emptyList()
                    }
                }
            }
            else -> emptyList()
        }.distinct()
    }

    private fun JsonElement.idOrName(): String? = when (this) {
        is JsonPrimitive -> contentOrNull?.takeIf { it.isNotBlank() }
        is JsonObject -> (this["id"] ?: this["name"] ?: this["model"])
            ?.let { (it as? JsonPrimitive)?.contentOrNull }
            ?.takeIf { it.isNotBlank() }
        else -> null
    }
}
