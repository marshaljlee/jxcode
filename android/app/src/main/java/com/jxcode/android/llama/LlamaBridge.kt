package com.jxcode.android.llama

/**
 * JNI bridge to llama.cpp, built for arm64-v8a by `native/build-native.sh`.
 *
 * Runs in-process rather than as a spawned `llama-server`: Android blocks
 * executing binaries from an app's writable data directory, so a subprocess
 * server is not an option here the way it is on macOS.
 *
 * The library is optional at runtime. If it is absent — a build without the
 * native step — [isAvailable] is false and every local call answers with a
 * "no model loaded" error instead of crashing the router.
 */
object LlamaBridge {

    fun interface TokenSink {
        /** Called on the native thread for every decoded token. */
        fun onToken(token: String)
    }

    private val libraryLoaded: Boolean by lazy {
        try {
            System.loadLibrary("jxllama")
            true
        } catch (t: Throwable) {
            android.util.Log.w("JXCodeLlama", "libjxllama.so not available: ${t.message}")
            false
        }
    }

    fun isAvailable(): Boolean = libraryLoaded

    @Volatile
    var loadedHandle: Long = 0L
        private set

    @Volatile
    var loadedPath: String? = null
        private set

    @Volatile
    var lastError: String? = null
        private set

    /**
     * The window the loaded model was opened with, in tokens.
     *
     * Read back rather than assumed: an agent told the wrong number overflows
     * the KV cache, and on a phone that is the difference between a model that
     * answers and one that dies mid-request.
     */
    @Volatile
    var loadedContextSize: Int = 0
        private set

    @Synchronized
    fun load(path: String, contextSize: Int = 4096, threads: Int = 4): Boolean {
        if (!isAvailable()) {
            lastError = "llama runtime not built into this APK"
            return false
        }
        unload()
        val handle = try {
            nativeLoad(path, contextSize, threads)
        } catch (t: Throwable) {
            lastError = t.message
            0L
        }
        loadedHandle = handle
        loadedPath = if (handle != 0L) path else null
        loadedContextSize = if (handle != 0L) contextSize else 0
        if (handle == 0L) lastError = lastError ?: "failed to load $path"
        return handle != 0L
    }

    @Synchronized
    fun unload() {
        val handle = loadedHandle
        if (handle != 0L) {
            runCatching { nativeFree(handle) }
        }
        loadedHandle = 0L
        loadedPath = null
        loadedContextSize = 0
    }

    fun cancel() {
        val handle = loadedHandle
        if (handle != 0L) runCatching { nativeStop(handle) }
    }

    /** Applies the model's own chat template, then generates. Returns full text. */
    fun chat(
        handle: Long,
        roles: Array<String>,
        contents: Array<String>,
        maxTokens: Int,
        sink: TokenSink? = null
    ): String = if (!isAvailable() || handle == 0L) "" else try {
        nativeChat(handle, roles, contents, maxTokens, sink)
    } catch (t: Throwable) {
        lastError = t.message
        ""
    }

    /** Rough peak footprint of a loaded model, for the doctor screen. */
    fun memoryBytes(): Long = if (loadedHandle == 0L) 0L else runCatching { nativeMemory(loadedHandle) }.getOrDefault(0L)

    private external fun nativeLoad(path: String, contextSize: Int, threads: Int): Long
    private external fun nativeFree(handle: Long)
    private external fun nativeChat(
        handle: Long,
        roles: Array<String>,
        contents: Array<String>,
        maxTokens: Int,
        sink: TokenSink?
    ): String
    private external fun nativeStop(handle: Long)
    private external fun nativeMemory(handle: Long): Long
}
