package com.jxcode.android.data

import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException

/**
 * The facts about a `.gguf` file that decide how it can be served.
 *
 * Ported from `Sources/JXCodeCore/GGUFModelInfo.swift` and `GGUFReader.swift`,
 * because the port needs the one number that matters most: **the context
 * length the model was trained for**. Until this existed the loader opened
 * every model at a hardcoded 4096 tokens, which is wrong in both directions —
 * a 32k model was served short, and a 2048-token model was opened at twice its
 * window and overflowed its KV cache on the first long request.
 *
 * The awkward part is that llama.cpp namespaces its metadata under the
 * architecture string: a Llama file stores `llama.context_length`, a Qwen file
 * stores `qwen2.context_length`. So the architecture has to be read first and
 * every other lookup is prefixed with it. That is the classic GGUF integration
 * bug — the keys look absent and the default silently wins.
 *
 * GGUF layout, all little-endian:
 *
 *     magic          u32   0x46554747 ("GGUF")
 *     version        u32   2 or 3
 *     tensor_count   u64
 *     kv_count       u64
 *     kv pairs...
 *     tensor descriptors...
 *     tensor data (aligned)
 *
 * Strings are `u64 length` followed by that many bytes of UTF-8 and are **not**
 * null-terminated, which is the detail that breaks naive parsers.
 */
data class GGUFModelInfo(
    val architecture: String?,
    val name: String?,
    /** The window the model was trained for, in tokens. */
    val contextLength: Int?,
    val blockCount: Int?,
    /** `Q4_K_M`, `F16`, … — what people actually call the quantisation. */
    val quantLabel: String?,
    val tensorCount: Long,
    /** Every metadata key seen, sorted. Enough to inspect an unknown arch. */
    val allKeys: List<String>
) {
    /** llama.cpp tags multimodal projectors with `general.architecture = clip`. */
    val isProjector: Boolean get() = architecture == "clip"

    /** `Llama · Q4_K_M · 8192 ctx`, skipping whatever is unknown. */
    fun summary(): String = listOfNotNull(
        architecture,
        quantLabel,
        contextLength?.let { "$it ctx" }
    ).joinToString(" · ").ifBlank { "unknown" }
}

object GGUFReader {

    private const val MAGIC = 0x46554747L

    /** GGUF versions this reader understands. 1 exists and is obsolete. */
    private val SUPPORTED_VERSIONS = 2L..3L

    // GGUF files are untrusted input — they are downloaded from the internet —
    // so every read is bounded. A corrupt file can claim `kv_count` is 2^63 or
    // that a string is 40 GB long.
    private const val MAX_KV_COUNT = 20_000L
    private const val MAX_ARRAY_COUNT = 50_000_000L
    private const val MAX_STRING_BYTES = 64L * 1024 * 1024
    private const val MAX_HEADER_BYTES = 64L * 1024 * 1024

    // GGUF value types.
    private const val T_UINT8 = 0L
    private const val T_INT8 = 1L
    private const val T_UINT16 = 2L
    private const val T_INT16 = 3L
    private const val T_UINT32 = 4L
    private const val T_INT32 = 5L
    private const val T_FLOAT32 = 6L
    private const val T_BOOL = 7L
    private const val T_STRING = 8L
    private const val T_ARRAY = 9L
    private const val T_UINT64 = 10L
    private const val T_INT64 = 11L
    private const val T_FLOAT64 = 12L

    /**
     * Reads the header and metadata of [file], or null when it is not a GGUF
     * file this reader understands.
     *
     * Only the header region is touched: the metadata of a real model lives in
     * the first few kilobytes and the tensor data behind it can be tens of
     * gigabytes. Array values — `tokenizer.ggml.tokens` is ~150,000 strings —
     * are **traversed but not materialised**, so a 9 GB file answers in
     * milliseconds instead of allocating hundreds of megabytes to skip past.
     */
    fun read(file: File): GGUFModelInfo? = try {
        BufferedInputStream(FileInputStream(file), 64 * 1024).use { stream ->
            parse(Cursor(stream))
        }
    } catch (_: Throwable) {
        // A model card is a nicety. A file that will not parse is still
        // loadable by llama.cpp, so a failure here is not an error the caller
        // has to handle — it just means the app falls back to its defaults.
        null
    }

    private fun parse(cursor: Cursor): GGUFModelInfo? {
        if (cursor.u32() != MAGIC) return null
        val version = cursor.u32()
        if (version !in SUPPORTED_VERSIONS) return null

        val tensorCount = cursor.u64()
        val kvCount = cursor.u64()
        if (kvCount < 0 || kvCount > MAX_KV_COUNT) return null

        // Keys are recorded whether or not the value survives: an array value
        // is skipped rather than materialised, and `tokenizer.ggml.tokens` is
        // still worth listing when someone inspects an unfamiliar architecture.
        val values = LinkedHashMap<String, Any>()
        val keys = mutableListOf<String>()
        for (index in 0 until kvCount) {
            if (cursor.position > MAX_HEADER_BYTES) break
            val key = cursor.string()
            keys += key
            val value = readValue(cursor)
            if (value != null) values[key] = value
        }

        val architecture = values["general.architecture"] as? String
        val prefix = architecture?.let { "$it." } ?: ""

        fun int(key: String): Int? = (values[key] as? Long)?.takeIf { it in 0..Int.MAX_VALUE }?.toInt()

        // The prefixed key is the correct one; the bare `*.context_length` scan
        // is the fallback for a file whose architecture key is missing or
        // spelled in a way this reader does not know.
        val contextLength = int("${prefix}context_length")
            ?: values.entries
                .firstOrNull { it.key.endsWith(".context_length") && it.value is Long }
                ?.value
                ?.let { (it as Long).takeIf { n -> n in 0..Int.MAX_VALUE }?.toInt() }

        return GGUFModelInfo(
            architecture = architecture,
            name = values["general.name"] as? String,
            contextLength = contextLength,
            blockCount = int("${prefix}block_count"),
            quantLabel = (values["general.file_type"] as? Long)?.let { quantLabel(it.toInt()) },
            tensorCount = tensorCount,
            allKeys = keys.sorted()
        )
    }

    /**
     * One metadata value, or null for an array — which is skipped structurally
     * rather than read. Thirteen GGUF types collapse onto four Kotlin shapes,
     * which is all the interpretation layer needs.
     */
    private fun readValue(cursor: Cursor): Any? = when (val type = cursor.u32()) {
        T_UINT8 -> cursor.unsigned(1)
        T_INT8 -> cursor.signed(1)
        T_UINT16 -> cursor.unsigned(2)
        T_INT16 -> cursor.signed(2)
        T_UINT32 -> cursor.unsigned(4)
        T_INT32 -> cursor.signed(4)
        T_UINT64 -> cursor.u64()
        T_INT64 -> cursor.u64()
        T_FLOAT32 -> java.lang.Float.intBitsToFloat(cursor.unsigned(4).toInt()).toDouble()
        T_FLOAT64 -> java.lang.Double.longBitsToDouble(cursor.u64())
        T_BOOL -> cursor.unsigned(1) != 0L
        T_STRING -> cursor.string()
        T_ARRAY -> { skipArray(cursor); null }
        else -> throw IOException("unknown GGUF value type $type")
    }

    private fun skipArray(cursor: Cursor) {
        val elementType = cursor.u32()
        val count = cursor.u64()
        if (count < 0 || count > MAX_ARRAY_COUNT) throw IOException("array of $count elements")
        for (index in 0 until count) {
            when (elementType) {
                T_STRING -> cursor.skip(cursor.u64())
                T_ARRAY -> skipArray(cursor)
                else -> cursor.skip(fixedWidth(elementType))
            }
        }
    }

    private fun fixedWidth(type: Long): Long = when (type) {
        T_UINT8, T_INT8, T_BOOL -> 1L
        T_UINT16, T_INT16 -> 2L
        T_UINT32, T_INT32, T_FLOAT32 -> 4L
        T_UINT64, T_INT64, T_FLOAT64 -> 8L
        else -> throw IOException("no fixed width for GGUF type $type")
    }

    /** `general.file_type`, as the label that appears in model filenames. */
    private fun quantLabel(fileType: Int): String? = when (fileType) {
        0 -> "F32"
        1 -> "F16"
        2 -> "Q4_0"
        3 -> "Q4_1"
        7 -> "Q8_0"
        8 -> "Q5_0"
        9 -> "Q5_1"
        10 -> "Q2_K"
        11 -> "Q3_K_S"
        12 -> "Q3_K_M"
        13 -> "Q3_K_L"
        14 -> "Q4_K_S"
        15 -> "Q4_K_M"
        16 -> "Q5_K_S"
        17 -> "Q5_K_M"
        18 -> "Q6_K"
        19 -> "IQ2_XXS"
        20 -> "IQ2_XS"
        21 -> "IQ2_S"
        22 -> "IQ2_M"
        23 -> "IQ3_XXS"
        24 -> "IQ3_S"
        25 -> "IQ3_M"
        26 -> "IQ1_S"
        27 -> "IQ4_NL"
        28 -> "IQ3_XS"
        29 -> "IQ1_M"
        30 -> "BF16"
        31 -> "Q4_0_4_4"
        32 -> "Q4_0_4_8"
        33 -> "Q4_0_8_8"
        34 -> "TQ1_0"
        35 -> "TQ2_0"
        36 -> "IQ4_XS"
        else -> null
    }

    /**
     * A forward-only reader that counts its own position.
     *
     * The position matters because the caller stops after a bounded number of
     * header bytes — the tokenizer arrays in a real model are megabytes and
     * there is nothing after them worth reading.
     */
    private class Cursor(private val input: BufferedInputStream) {

        var position: Long = 0
            private set

        private fun bytes(count: Int): ByteArray {
            val buffer = ByteArray(count)
            var filled = 0
            while (filled < count) {
                val read = input.read(buffer, filled, count - filled)
                if (read < 0) throw IOException("GGUF ended after $position bytes")
                filled += read
            }
            position += count
            return buffer
        }

        fun unsigned(width: Int): Long {
            val buffer = bytes(width)
            var value = 0L
            for (index in width - 1 downTo 0) {
                value = (value shl 8) or (buffer[index].toLong() and 0xFF)
            }
            return value
        }

        /** Sign-extends, so a negative INT32 arrives as a negative Long. */
        fun signed(width: Int): Long {
            val raw = unsigned(width)
            val shift = 64 - width * 8
            return (raw shl shift) shr shift
        }

        fun u64(): Long = unsigned(8)

        fun u32(): Long = unsigned(4)

        fun string(): String {
            val length = u64()
            if (length < 0 || length > MAX_STRING_BYTES) throw IOException("string of $length bytes")
            return String(bytes(length.toInt()), Charsets.UTF_8)
        }

        fun skip(count: Long) {
            var remaining = count
            while (remaining > 0) {
                val skipped = input.skip(remaining)
                if (skipped <= 0) throw IOException("could not skip $remaining bytes")
                remaining -= skipped
                position += skipped
            }
        }
    }
}
