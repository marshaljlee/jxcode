package com.jxcode.android.router

import android.content.Context
import android.util.Log
import com.jxcode.android.data.Provider
import com.jxcode.android.data.ProviderKind
import com.jxcode.android.data.ProviderStore
import com.jxcode.android.llama.LlamaBridge
import com.jxcode.android.net.HttpFraming
import com.jxcode.android.net.HttpRequest
import com.jxcode.android.net.HttpResponseWriter
import com.jxcode.android.wire.AnthropicContentBlock
import com.jxcode.android.wire.AnthropicErrorEnvelope
import com.jxcode.android.wire.AnthropicRequest
import com.jxcode.android.wire.AnthropicResponse
import com.jxcode.android.wire.AnthropicSSE
import com.jxcode.android.wire.AnthropicUsage
import com.jxcode.android.wire.OpenAIChatRequest
import com.jxcode.android.wire.OpenAIChatResponse
import com.jxcode.android.wire.OpenAIMessage
import com.jxcode.android.wire.OpenAIModel
import com.jxcode.android.wire.OpenAIModelList
import com.jxcode.android.wire.TokenEstimator
import com.jxcode.android.wire.Translation
import com.jxcode.android.wire.WireJson
import com.jxcode.android.wire.asCompactJson
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The loopback server every agent CLI talks to.
 *
 * This replaces the macOS build's `NWListener`, which is Network.framework and
 * therefore Apple-only. Binding is deliberately restricted to 127.0.0.1 and
 * there is no authentication — the same trust boundary as local Ollama or LM
 * Studio. On Android the boundary is stronger than on macOS: no other uid can
 * reach this app's loopback port without the INTERNET permission and the kernel
 * keeps the app in its own sandbox regardless.
 */
class ModelRouter(private val context: Context) {

    companion object {
        const val DEFAULT_PORT = 5255
        private const val TAG = "JXCodeRouter"
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 0 // streaming: no read timeout
        private const val MAX_LOG_LINES = 200
    }

    /** What the router is currently pointed at. Held separately from the
     * provider store because it changes far more often: switching model in the
     * UI must take effect on the next request without restarting the listener. */
    data class Configuration(
        val provider: Provider? = null,
        val model: String? = null,
        val aliases: Set<String> = emptySet(),
        val port: Int = DEFAULT_PORT
    ) {
        val isReady: Boolean get() = provider != null && model != null
    }

    @Volatile
    var configuration: Configuration = Configuration()
        private set

    @Volatile
    var port: Int? = null
        private set

    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "jxcode-router").apply { isDaemon = true }
    }

    /** Bounded, newest-last ring of human-readable events. */
    private val logLines = Collections.synchronizedList(mutableListOf<String>())

    fun log(): List<String> = synchronized(logLines) { logLines.toList() }

    fun log(line: String) {
        Log.d(TAG, line)
        synchronized(logLines) {
            logLines.add(line)
            if (logLines.size > MAX_LOG_LINES) logLines.removeAt(0)
        }
    }

    val baseURL: String? get() = port?.let { "http://127.0.0.1:$it" }

    fun update(provider: Provider?, model: String?, port: Int = configuration.port) {
        configuration = Configuration(provider, model, configuration.aliases, port)
        log("router -> ${provider?.name ?: "none"} model=${model ?: "none"}")
    }

    /** Binds loopback. Returns the port actually bound, or throws. */
    @Synchronized
    fun start(requestedPort: Int = configuration.port): Int {
        if (running.get()) return port ?: requestedPort

        var bound: ServerSocket? = null
        var actualPort = requestedPort
        // A leftover port from a previous process is the common failure, so
        // walk a short range instead of refusing to start.
        for (candidate in requestedPort until requestedPort + 10) {
            try {
                bound = ServerSocket(candidate, 64, InetAddress.getByName("127.0.0.1"))
                actualPort = candidate
                break
            } catch (_: Exception) {
                continue
            }
        }
        val socket = bound ?: throw IllegalStateException("could not bind a loopback port near $requestedPort")

        server = socket
        running.set(true)
        port = actualPort
        configuration = configuration.copy(port = actualPort)
        log("listening on 127.0.0.1:$actualPort")

        pool.execute {
            while (running.get()) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    if (running.get()) log("accept failed")
                    break
                }
                pool.execute { serve(client) }
            }
        }
        return actualPort
    }

    fun stop() {
        running.set(false)
        runCatching { server?.close() }
        server = null
        port = null
        log("stopped")
    }

    private fun serve(client: Socket) {
        try {
            client.use { socket ->
                socket.soTimeout = 0
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                val writer = HttpResponseWriter(output)
                val request = HttpFraming.read(input) ?: return
                handle(request, writer)
            }
        } catch (e: Exception) {
            log("client error: ${e.message}")
        }
    }

    // MARK: - Routing

    private fun handle(request: HttpRequest, writer: HttpResponseWriter) {
        val path = request.path.substringBefore('?')
        log("${request.method} $path")

        when {
            request.method == "GET" && (path == "/health" || path == "/v1/health") -> {
                val body = buildJsonObject {
                    put("status", "ok")
                    val name = configuration.provider?.name
                    if (name != null) put("provider", name) else put("provider", JsonNull)
                    val model = configuration.model
                    if (model != null) put("model", model) else put("model", JsonNull)
                    val bound = port
                    if (bound != null) put("port", bound) else put("port", JsonNull)
                    put("llama", LlamaBridge.isAvailable())
                }
                writer.json(200, WireJson.encodeToString(JsonObject.serializer(), body))
            }

            request.method == "GET" && (path == "/v1/models" || path == "/models") -> {
                writer.json(200, WireJson.encodeToString(OpenAIModelList.serializer(), modelsPayload()))
            }

            request.method == "POST" && path == "/v1/messages/count_tokens" -> countTokens(request, writer)

            request.method == "POST" && path == "/v1/messages" -> messages(request, writer, anthropicStyle = true)

            request.method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") ->
                chatCompletions(request, writer)

            else -> {
                val message = "no route for ${request.method} $path"
                writer.json(404, WireJson.encodeToString(AnthropicErrorEnvelope.serializer(), AnthropicErrorEnvelope.apiError(message)))
            }
        }
    }

    private fun modelsPayload(): OpenAIModelList {
        val ids = mutableListOf<String>()
        configuration.model?.let { ids.add(it) }
        configuration.aliases.forEach { ids.add(it) }
        configuration.provider?.models?.let { ids.addAll(it) }
        return OpenAIModelList(data = ids.distinct().map { OpenAIModel(id = it) })
    }

    private fun countTokens(request: HttpRequest, writer: HttpResponseWriter) {
        val parsed = runCatching {
            WireJson.decodeFromString(AnthropicRequest.serializer(), request.bodyText)
        }.getOrNull()
        if (parsed == null) {
            writer.json(400, WireJson.encodeToString(AnthropicErrorEnvelope.serializer(), AnthropicErrorEnvelope.apiError("body is not an Anthropic count_tokens request")))
            return
        }
        val response = com.jxcode.android.wire.AnthropicCountTokensResponse(
            inputTokens = TokenEstimator.estimate(parsed)
        )
        writer.json(200, WireJson.encodeToString(com.jxcode.android.wire.AnthropicCountTokensResponse.serializer(), response))
    }

    // MARK: /v1/messages

    private fun messages(request: HttpRequest, writer: HttpResponseWriter, anthropicStyle: Boolean) {
        val provider = configuration.provider
        val model = configuration.model
        if (provider == null || model == null) {
            writer.json(500, errorJSON("No backend selected. Pick a provider and model in the Providers tab.", anthropicStyle))
            return
        }

        val source = runCatching {
            WireJson.decodeFromString(AnthropicRequest.serializer(), request.bodyText)
        }.getOrNull()
        if (source == null) {
            writer.json(400, errorJSON("body is not an Anthropic messages request", anthropicStyle))
            return
        }

        val requestedModel = source.model
        val target = resolveModel(requestedModel, model)
        val streaming = source.stream == true
        log("POST /v1/messages stream=$streaming kind=${provider.kind}")

        val apiKey = ProviderStore(context).apiKey(provider)

        if (provider.kind == ProviderKind.Anthropic) {
            forwardAnthropic(provider, apiKey, source.copy(model = target), streaming, writer)
            return
        }

        // Everything else speaks OpenAI Chat Completions — including the
        // on-device GGUF runtime, which is reached in-process.
        val translated = Translation.request(source.copy(model = target))
        translated.notes.forEach { log("note: $it") }

        if (provider.kind == ProviderKind.LocalGGUF) {
            runLocal(translated.request, requestedModel, streaming, writer)
            return
        }

        forwardOpenAI(provider, apiKey, translated.request, requestedModel, streaming, writer)
    }

    // MARK: /v1/chat/completions

    private fun chatCompletions(request: HttpRequest, writer: HttpResponseWriter) {
        val provider = configuration.provider
        val model = configuration.model
        if (provider == null || model == null) {
            writer.json(500, openAIError("No backend selected. Pick a provider and model in the Providers tab."))
            return
        }

        val source = runCatching {
            WireJson.decodeFromString(OpenAIChatRequest.serializer(), request.bodyText)
        }.getOrNull()
        if (source == null) {
            writer.json(400, openAIError("body is not a chat completions request"))
            return
        }

        val requestedModel = source.model
        val target = resolveModel(requestedModel, model)
        val streaming = source.stream == true
        log("POST /v1/chat/completions stream=$streaming kind=${provider.kind}")
        val apiKey = ProviderStore(context).apiKey(provider)

        when (provider.kind) {
            ProviderKind.LocalGGUF -> runLocal(
                source.copy(model = target), requestedModel, streaming, writer
            )
            ProviderKind.Anthropic -> {
                // Reverse direction: an OpenAI-speaking agent on an Anthropic
                // backend. Translate up, then translate the answer back down.
                val anthropic = Translation.anthropicRequest(source.copy(model = target))
                val response = callAnthropic(provider, apiKey, anthropic)
                if (response == null) {
                    writer.json(500, openAIError(unreachable(provider)))
                    return
                }
                val openAI = Translation.openAIResponse(response)
                writer.json(200, WireJson.encodeToString(OpenAIChatResponse.serializer(), openAI))
            }
            ProviderKind.OpenAI -> forwardOpenAI(
                provider, apiKey, source.copy(model = target), requestedModel, streaming, writer
            )
        }
    }

    // MARK: - Upstream

    private fun forwardAnthropic(
        provider: Provider,
        apiKey: String?,
        request: AnthropicRequest,
        streaming: Boolean,
        writer: HttpResponseWriter
    ) {
        val url = appendPath(provider.normalizedBaseURL, "/v1/messages")
        var connection: HttpURLConnection? = null
        try {
            connection = open(url, apiKey, anthropic = true)
            val payload = WireJson.encodeToString(AnthropicRequest.serializer(), request)
            connection.outputStream.use { it.write(payload.toByteArray(StandardCharsets.UTF_8)) }
            val status = connection.responseCode
            if (status !in 200..299) {
                val detail = readError(connection, url)
                log("upstream $status: $detail")
                writer.json(500, errorJSON("Upstream error $status: $detail", true))
                return
            }
            if (streaming) {
                writer.head(200, "OK", mapOf("Content-Type" to "text/event-stream", "Cache-Control" to "no-cache"), chunked = true)
                pumpText(connection) { line -> writer.writeChunk(line + "\n") }
                writer.end()
            } else {
                val text = connection.inputStream.bufferedReader().readText()
                writer.json(200, text)
            }
        } catch (e: Exception) {
            log("upstream failure: ${e.message}")
            writer.json(500, errorJSON(unreachable(provider, e), true))
        } finally {
            connection?.disconnect()
        }
    }

    /**
     * Anthropic client, OpenAI-shaped backend. Streams by translating each
     * upstream chunk into Anthropic frames as it arrives.
     */
    private fun forwardOpenAI(
        provider: Provider,
        apiKey: String?,
        request: OpenAIChatRequest,
        requestedModel: String,
        streaming: Boolean,
        writer: HttpResponseWriter
    ) {
        val url = appendPath(provider.normalizedBaseURL, "/v1/chat/completions")
        var connection: HttpURLConnection? = null
        try {
            connection = open(url, apiKey, anthropic = false)
            val payload = WireJson.encodeToString(OpenAIChatRequest.serializer(), request)
            connection.outputStream.use { it.write(payload.toByteArray(StandardCharsets.UTF_8)) }

            val status = connection.responseCode
            if (status !in 200..299) {
                val detail = readError(connection, url)
                log("upstream $status: $detail")
                writer.json(500, errorJSON("Upstream error $status: $detail", true))
                return
            }

            if (!streaming) {
                val text = connection.inputStream.bufferedReader().readText()
                val response = runCatching {
                    WireJson.decodeFromString(OpenAIChatResponse.serializer(), text)
                }.getOrNull()
                if (response == null) {
                    writer.json(502, errorJSON("upstream returned a body this router could not parse", true))
                    return
                }
                val anthropic = Translation.response(response, requestedModel)
                writer.json(200, WireJson.encodeToString(AnthropicResponse.serializer(), anthropic))
                return
            }

            writer.head(200, "OK", mapOf("Content-Type" to "text/event-stream", "Cache-Control" to "no-cache"), chunked = true)
            val translator = Translation.StreamTranslator(model = requestedModel, inputTokens = 0)
            pumpSSE(connection) { data ->
                if (data == "[DONE]") return@pumpSSE
                val chunk = runCatching {
                    WireJson.decodeFromString(OpenAIChatResponse.serializer(), data)
                }.getOrNull() ?: return@pumpSSE
                for (frame in translator.consume(chunk)) writer.writeChunk(frame)
            }
            // Termination is emitted on upstream EOF, not on finish_reason:
            // with include_usage the real counts arrive in a later chunk.
            for (frame in translator.finalize()) writer.writeChunk(frame)
            writer.end()
        } catch (e: Exception) {
            log("upstream failure: ${e.message}")
            runCatching { writer.json(500, errorJSON(unreachable(provider, e), true)) }
        } finally {
            connection?.disconnect()
        }
    }

    /** On-device GGUF through the JNI bridge, in-process. */
    private fun runLocal(
        request: OpenAIChatRequest,
        requestedModel: String,
        streaming: Boolean,
        writer: HttpResponseWriter
    ) {
        val handle = LlamaBridge.loadedHandle
        if (handle == 0L || !LlamaBridge.isAvailable()) {
            writer.json(500, errorJSON(
                "No model is loaded on device. Load a GGUF in the Models tab first, then select this provider.",
                true
            ))
            return
        }

        val roles = request.messages.map { it.role }.toTypedArray()
        val contents = request.messages.map { it.plainText }.toTypedArray()
        val maxTokens = request.maxTokens ?: 512

        if (!streaming) {
            val text = LlamaBridge.chat(handle, roles, contents, maxTokens) { }
            val response = AnthropicResponse(
                id = Translation.newMessageId(),
                model = requestedModel,
                content = listOf(AnthropicContentBlock.Text(text)),
                stopReason = "end_turn",
                usage = AnthropicUsage(inputTokens = 0, outputTokens = TokenEstimator.count(text))
            )
            writer.json(200, WireJson.encodeToString(AnthropicResponse.serializer(), response))
            return
        }

        writer.head(200, "OK", mapOf("Content-Type" to "text/event-stream", "Cache-Control" to "no-cache"), chunked = true)
        val messageID = Translation.newMessageId()
        writer.writeChunk(AnthropicSSE.messageStart(messageID, requestedModel, 0))
        writer.writeChunk(AnthropicSSE.textBlockStart(0))
        var produced = ""
        // The callback fires from the native thread, so writes are funnelled
        // through a lock rather than assumed to be single-threaded.
        val lock = Any()
        LlamaBridge.chat(handle, roles, contents, maxTokens) { token ->
            synchronized(lock) {
                produced += token
                writer.writeChunk(AnthropicSSE.textDelta(0, token))
            }
        }
        writer.writeChunk(AnthropicSSE.contentBlockStop(0))
        writer.writeChunk(AnthropicSSE.messageDelta("end_turn", TokenEstimator.count(produced).coerceAtLeast(1)))
        writer.writeChunk(AnthropicSSE.messageStop())
        writer.end()
    }

    private fun callAnthropic(provider: Provider, apiKey: String?, request: AnthropicRequest): AnthropicResponse? {
        val url = appendPath(provider.normalizedBaseURL, "/v1/messages")
        var connection: HttpURLConnection? = null
        return try {
            connection = open(url, apiKey, anthropic = true)
            val payload = WireJson.encodeToString(AnthropicRequest.serializer(), request)
            connection.outputStream.use { it.write(payload.toByteArray(StandardCharsets.UTF_8)) }
            val status = connection.responseCode
            if (status !in 200..299) {
                log("upstream $status: ${readError(connection, url)}")
                null
            } else {
                val text = connection.inputStream.bufferedReader().readText()
                runCatching { WireJson.decodeFromString(AnthropicResponse.serializer(), text) }.getOrNull()
            }
        } catch (e: Exception) {
            log("upstream failure: ${e.message}")
            null
        } finally {
            connection?.disconnect()
        }
    }

    // MARK: - Helpers

    private fun open(url: String, apiKey: String?, anthropic: Boolean): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Accept", if (anthropic) "application/json" else "text/event-stream")
            if (!apiKey.isNullOrBlank()) {
                setRequestProperty("Authorization", "Bearer $apiKey")
                setRequestProperty("x-api-key", apiKey)
            }
            if (anthropic) setRequestProperty("anthropic-version", "2023-06-01")
        }

    private fun readError(connection: HttpURLConnection, url: String): String =
        runCatching {
            val stream = connection.errorStream ?: connection.inputStream
            stream.bufferedReader().readText().take(300)
        }.getOrDefault("(no body) from $url")

    /** Relay raw text lines — used for a native Anthropic stream. */
    private fun pumpText(connection: HttpURLConnection, emit: (String) -> Unit) {
        BufferedReader(InputStreamReader(connection.inputStream, StandardCharsets.UTF_8)).use { reader ->
            while (true) {
                val line = reader.readLine() ?: break
                emit(line)
            }
        }
    }

    /** Parse `data:` frames; the blank line between events is the terminator. */
    private fun pumpSSE(connection: HttpURLConnection, emit: (String) -> Unit) {
        BufferedReader(InputStreamReader(connection.inputStream, StandardCharsets.UTF_8)).use { reader ->
            var data = StringBuilder()
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) {
                    if (data.isNotEmpty()) {
                        emit(data.toString().trim())
                        data = StringBuilder()
                    }
                    continue
                }
                if (line.startsWith("data:")) {
                    data.append(line.removePrefix("data:").trimStart()).append('\n')
                }
            }
            if (data.isNotEmpty()) emit(data.toString().trim())
        }
    }

    /**
     * Which model to actually ask for.
     *
     * Anything Claude-shaped is intercepted regardless — the client's own model
     * names are what the backend does not have — but an explicit model the
     * provider advertises is passed through untouched.
     */
    private fun resolveModel(requested: String, configured: String): String {
        val provider = configuration.provider
        if (provider != null && provider.models.any { it == requested }) return requested
        val lower = requested.lowercase()
        val intercepted = lower.startsWith("claude") || lower.startsWith("gpt-") ||
            lower.startsWith("o1") || lower.startsWith("o3") || lower.startsWith("o4") ||
            lower.startsWith("gemini") || lower in configuration.aliases.map { it.lowercase() }
        return if (intercepted) configured else requested
    }

    private fun appendPath(base: String, path: String): String {
        val trimmed = base.trim().trimEnd('/')
        if (trimmed.endsWith(path)) return trimmed
        return if (trimmed.endsWith("/v1")) "$trimmed${path.removePrefix("/v1")}" else "$trimmed$path"
    }

    private fun unreachable(provider: Provider, error: Exception? = null): String {
        val base = "Could not reach ${provider.normalizedBaseURL}${error?.message?.let { ": $it" } ?: "."}"
        // A stale local provider is the single most confusing failure, so it
        // says what to do rather than just what happened.
        return if (provider.kind == ProviderKind.LocalGGUF) {
            "$base No model is loaded on device: load a GGUF in the Models tab first, or select a backend that is running."
        } else {
            "$base Check the backend is running and the URL is reachable from this device."
        }
    }

    private fun errorJSON(message: String, anthropicStyle: Boolean): String =
        if (anthropicStyle) {
            WireJson.encodeToString(AnthropicErrorEnvelope.serializer(), AnthropicErrorEnvelope.apiError(message))
        } else {
            openAIError(message)
        }

    private fun openAIError(message: String): String = WireJson.encodeToString(
        JsonObject.serializer(),
        buildJsonObject {
            putJsonObject("error") {
                put("message", message)
                put("type", "api_error")
            }
        }
    )
}
