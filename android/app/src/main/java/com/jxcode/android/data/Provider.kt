package com.jxcode.android.data

import android.content.Context
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

@Serializable
enum class ProviderKind {
    @SerialName("anthropic") Anthropic,
    @SerialName("openai") OpenAI,
    @SerialName("localGGUF") LocalGGUF;

    val displayName: String
        get() = when (this) {
            Anthropic -> "Anthropic-compatible"
            OpenAI -> "OpenAI-compatible"
            LocalGGUF -> "Local GGUF (on-device)"
        }
}

/**
 * A registered backend.
 *
 * `apiKeyAlias` names a secret in [SecretStore]; the key itself never lives in
 * this object, so it cannot leak into a JSON dump, a log line or a backup.
 */
@Serializable
data class Provider(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val baseURL: String,
    val kind: ProviderKind = ProviderKind.OpenAI,
    val apiKeyAlias: String? = null,
    val models: List<String> = emptyList(),
    val isBuiltIn: Boolean = false,
    /**
     * The context window the backend can actually hold, in tokens.
     *
     * Optional and defaulted, so a `providers.json` written before this field
     * existed still decodes. It lives here because the window is a fact about
     * the backend, not about the model the UI happens to have selected: an
     * agent that assumes a 200k window against a 4k local model overflows on
     * its first request, and the failure reads as a crash rather than as a
     * size problem.
     */
    val contextLength: Int? = null
) {
    /** Trailing slashes only: `/v1` is part of some backends' real path. */
    val normalizedBaseURL: String get() = baseURL.trim().trimEnd('/')

    companion object {
        fun local(port: Int, model: String, contextLength: Int? = null) = Provider(
            name = "Local GGUF (on-device)",
            baseURL = "http://127.0.0.1:$port",
            kind = ProviderKind.LocalGGUF,
            models = listOf(model),
            isBuiltIn = true,
            contextLength = contextLength
        )
    }
}

/**
 * Persisted provider list.
 *
 * `add` collapses on `(normalizedBaseURL, kind)` and not only on `id`: the
 * macOS build deduped on `id` alone, so registering the same backend twice —
 * which the UI does whenever a model is served — appended duplicate entries
 * that all pointed at the same port.
 */
class ProviderStore(private val context: Context) {

    private val file = File(context.filesDir, "providers.json")
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
        encodeDefaults = true
    }

    private var providers: MutableList<Provider> = load()

    fun all(): List<Provider> = providers.toList()

    fun get(id: String): Provider? = providers.firstOrNull { it.id == id }

    fun add(provider: Provider): Provider {
        val existing = providers.indexOfFirst {
            it.id == provider.id ||
                (it.normalizedBaseURL == provider.normalizedBaseURL && it.kind == provider.kind)
        }
        if (existing >= 0) {
            providers[existing] = provider
        } else {
            providers.add(provider)
        }
        save()
        return provider
    }

    fun remove(id: String) {
        providers.removeAll { it.id == id }
        save()
    }

    fun update(provider: Provider) = add(provider)

    fun apiKey(forProvider: Provider): String? =
        forProvider.apiKeyAlias?.let { SecretStore.get(context, it) }

    fun setApiKey(forProvider: Provider, key: String): Provider {
        val alias = forProvider.apiKeyAlias ?: "provider_${forProvider.id}"
        SecretStore.put(context, alias, key)
        return add(forProvider.copy(apiKeyAlias = alias))
    }

    private val contextField = context

    private fun load(): MutableList<Provider> {
        if (!file.exists()) return mutableListOf()
        return try {
            json.decodeFromString<List<Provider>>(file.readText()).toMutableList()
        } catch (_: Throwable) {
            mutableListOf()
        }
    }

    private fun save() {
        try {
            file.parentFile?.mkdirs()
            file.writeText(json.encodeToString(providers))
        } catch (_: Throwable) {
            // A failed save must not take down the router; the in-memory list
            // stays authoritative for this session.
        }
    }
}
