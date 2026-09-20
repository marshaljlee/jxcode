package com.jxcode.android.terminal

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Owns one pty and drives a [TerminalBuffer] from it.
 *
 * Output crosses threads: the reader thread decodes bytes and queues strings,
 * and the buffer is only ever mutated on the main thread. That keeps the
 * renderer — which walks every cell — free of locking, and batches arrival
 * into frame-sized updates rather than one recomposition per read.
 */
class TerminalSession(
    val buffer: TerminalBuffer,
    private val scope: CoroutineScope
) {

    companion object {
        private const val TAG = "JXCodeTerm"
        private const val READ_SIZE = 16 * 1024
    }

    private var handle: Long = 0L
    private var reader: Thread? = null
    private var drainJob: Job? = null

    private val pending = ConcurrentLinkedQueue<String>()

    @Volatile
    var exitCode: Int? = null
        private set

    @Volatile
    var lastError: String? = null
        private set

    val isRunning: Boolean get() = handle != 0L

    fun start(
        command: String,
        args: Array<String> = emptyArray(),
        env: Array<String> = emptyArray(),
        cwd: String = "/"
    ): Boolean {
        if (!PtyNative.available) {
            lastError = "pty support is not built into this APK (libjxpty.so missing)"
            return false
        }
        handle = try {
            PtyNative.spawn(command, args, env, cwd, buffer.rows, buffer.cols)
        } catch (t: Throwable) {
            lastError = t.message
            0L
        }
        if (handle == 0L) {
            lastError = lastError ?: "could not start $command"
            return false
        }

        val localHandle = handle
        reader = Thread({
            val bytes = ByteArray(READ_SIZE)
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPLACE)
                .onUnmappableCharacter(CodingErrorAction.REPLACE)
            while (!Thread.currentThread().isInterrupted) {
                val count = try {
                    PtyNative.read(localHandle, bytes)
                } catch (t: Throwable) {
                    -1
                }
                when {
                    count > 0 -> {
                        // A chunk boundary can split a multi-byte scalar; the
                        // decoder is carried across reads so it cannot corrupt.
                        val text = try {
                            decoder.decode(ByteBuffer.wrap(bytes, 0, count)).toString()
                        } catch (t: Throwable) {
                            String(bytes, 0, count, StandardCharsets.UTF_8)
                        }
                        if (text.isNotEmpty()) pending.add(text)
                    }
                    count == 0 -> try { Thread.sleep(16) } catch (_: InterruptedException) { break }
                    else -> break
                }
            }
            exitCode = try { PtyNative.waitFor(localHandle, 500) } catch (_: Throwable) { -1 }
            Log.d(TAG, "reader ended exit=$exitCode")
        }, "jxcode-pty-reader").apply { isDaemon = true; start() }

        drainJob = scope.launch(Dispatchers.Main) {
            while (isActive) {
                drain()
                delay(16)
            }
        }
        return true
    }

    /** Called on the main thread: the only place the buffer is mutated. */
    fun drain() {
        if (pending.isEmpty()) return
        val builder = StringBuilder()
        while (true) {
            val next = pending.poll() ?: break
            builder.append(next)
            if (builder.length > 64 * 1024) break
        }
        if (builder.isNotEmpty()) buffer.write(builder.toString())
    }

    fun write(text: String) {
        if (handle == 0L) return
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        try {
            PtyNative.write(handle, bytes)
        } catch (t: Throwable) {
            lastError = t.message
        }
    }

    fun resize(rows: Int, cols: Int) {
        buffer.resize(cols, rows)
        if (handle != 0L) {
            try {
                PtyNative.resize(handle, rows, cols)
            } catch (_: Throwable) { }
        }
    }

    fun stop() {
        drainJob?.cancel()
        drainJob = null
        val local = handle
        handle = 0L
        if (local != 0L) {
            runCatching { PtyNative.signal(local, 15) }
            runCatching { PtyNative.close(local) }
        }
        reader?.interrupt()
        reader = null
    }
}
