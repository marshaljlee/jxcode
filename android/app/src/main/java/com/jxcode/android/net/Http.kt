package com.jxcode.android.net

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.charset.StandardCharsets

/**
 * Incremental HTTP/1.1 framing.
 *
 * **Parsing is done at the byte level, on `0x0A`, with a trailing `0x0D`
 * stripped.** On the macOS build the head was originally split on the *string*
 * `"\n"`, which silently returned the whole CRLF head as a single line —
 * headers, `Content-Length` included, were lost while the request line still
 * parsed by luck. The symptom was a 500 with an empty body. Never split an
 * HTTP head on a newline *character*: in Swift `\r\n` is one grapheme cluster,
 * and in Kotlin a string split on `"\n"` leaves a stray `\r` on every field.
 */
data class HttpRequest(
    val method: String,
    val path: String,
    val version: String,
    private val rawHeaders: Map<String, String>,
    val body: ByteArray
) {
    /** Header lookup is case-insensitive by spec; keys are stored lower-cased. */
    fun header(name: String): String? = rawHeaders[name.lowercase()]

    val contentLength: Int? get() = header("content-length")?.trim()?.toIntOrNull()

    val isChunked: Boolean
        get() = header("transfer-encoding")?.contains("chunked", ignoreCase = true) == true

    val bodyText: String get() = body.toString(StandardCharsets.UTF_8)
}

object HttpFraming {

    private const val MAX_HEAD_BYTES = 64 * 1024

    /** Reads one request head + body, or null at EOF. */
    fun read(input: InputStream): HttpRequest? {
        val headBytes = readUntilBlankLine(input) ?: return null
        val head = headBytes.toString(StandardCharsets.UTF_8)
        val lines = head.split('\n').map { it.removeSuffix("\r") }

        val requestLine = lines.firstOrNull() ?: return null
        val parts = requestLine.split(' ')
        if (parts.size < 2) return null
        val method = parts[0]
        val path = parts[1]
        val version = parts.getOrNull(2) ?: "HTTP/1.1"

        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            if (line.isBlank()) continue
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val name = line.substring(0, colon).trim().lowercase()
            val value = line.substring(colon + 1).trim()
            // Duplicate headers join rather than overwrite: proxies do this.
            headers[name] = headers[name]?.let { "$it, $value" } ?: value
        }

        val contentLength = headers["content-length"]?.toIntOrNull()
        val body = when {
            contentLength != null && contentLength > 0 -> readExactly(input, contentLength)
            headers["transfer-encoding"]?.contains("chunked", true) == true -> readChunked(input)
            else -> ByteArray(0)
        }

        return HttpRequest(method, path, version, headers, body)
    }

    private fun readUntilBlankLine(input: InputStream): ByteArray? {
        val buffer = ByteArrayOutputStream()
        var consecutiveLf = 0
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (buffer.size() == 0) null else buffer.toByteArray()
            buffer.write(byte)
            if (buffer.size() > MAX_HEAD_BYTES) return buffer.toByteArray()
            when (byte) {
                0x0A -> {
                    // "\n\n" and "\r\n\r\n" both end with two 0x0A bytes; the
                    // 0x0D is skipped rather than tested for.
                    consecutiveLf++
                    if (consecutiveLf >= 2) return buffer.toByteArray()
                }
                0x0D -> Unit
                else -> consecutiveLf = 0
            }
        }
    }

    private fun readExactly(input: InputStream, length: Int): ByteArray {
        val out = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(out, offset, length - offset)
            if (read < 0) break
            offset += read
        }
        return out.copyOf(offset)
    }

    private fun readChunked(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        while (true) {
            val sizeLine = readAsciiLine(input) ?: break
            val size = sizeLine.trim().takeWhile { it != ';' }.toIntOrNull(16) ?: break
            if (size == 0) {
                readAsciiLine(input) // trailing blank line
                break
            }
            out.write(readExactly(input, size))
            readAsciiLine(input) // CRLF after chunk data
        }
        return out.toByteArray()
    }

    private fun readAsciiLine(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (out.size() == 0) null else out.toString(Charsets.ISO_8859_1.name())
            if (byte == 0x0A) return out.toByteArray().toString(Charsets.ISO_8859_1).removeSuffix("\r")
            if (byte != 0x0D) out.write(byte)
        }
    }
}

/** Writes HTTP/1.1 responses, including chunked streaming. */
class HttpResponseWriter(private val output: OutputStream) {

    private var chunked = false

    fun head(status: Int, reason: String, headers: Map<String, String>, chunked: Boolean = false) {
        this.chunked = chunked
        val text = buildString {
            append("HTTP/1.1 $status $reason\r\n")
            if (chunked) {
                append("Transfer-Encoding: chunked\r\n")
            }
            for ((name, value) in headers) append("$name: $value\r\n")
            append("Connection: close\r\n")
            append("\r\n")
        }
        output.write(text.toByteArray(StandardCharsets.UTF_8))
        output.flush()
    }

    fun body(status: Int, reason: String, contentType: String, bytes: ByteArray, extraHeaders: Map<String, String> = emptyMap()) {
        val headers = mutableMapOf(
            "Content-Type" to contentType,
            "Content-Length" to bytes.size.toString(),
            "Cache-Control" to "no-store"
        )
        headers.putAll(extraHeaders)
        head(status, reason, headers, chunked = false)
        output.write(bytes)
        output.flush()
    }

    fun json(status: Int, text: String) = body(status, statusReason(status), "application/json", text.toByteArray(StandardCharsets.UTF_8))

    fun writeChunk(bytes: ByteArray) {
        if (!chunked) return
        output.write("${bytes.size.toString(16)}\r\n".toByteArray(StandardCharsets.UTF_8))
        output.write(bytes)
        output.write("\r\n".toByteArray(StandardCharsets.UTF_8))
        output.flush()
    }

    fun writeChunk(text: String) = writeChunk(text.toByteArray(StandardCharsets.UTF_8))

    fun end() {
        if (chunked) {
            output.write("0\r\n\r\n".toByteArray(StandardCharsets.UTF_8))
            output.flush()
        }
    }

    fun statusReason(status: Int): String = when (status) {
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        500 -> "Internal Server Error"
        502 -> "Bad Gateway"
        504 -> "Gateway Timeout"
        else -> "Status"
    }

    private fun statusReasonUnused() {}
}
