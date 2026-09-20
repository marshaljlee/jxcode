package com.jxcode.android.terminal

import android.util.Log

/**
 * JNI pty: `forkpty` + `execve`, the Android equivalent of the macOS build's
 * `PTYSession`.
 *
 * Android has no `posix_spawn` pty helper and no `login_tty`, but bionic does
 * provide `openpty`/`forkpty` in `<pty.h>`, which is what this uses.
 *
 * The library is loaded lazily and its absence is reported rather than fatal:
 * a build without the native step still runs, with the terminal screen saying
 * so instead of the app crashing at class-init time.
 */
object PtyNative {

    private const val TAG = "JXCodePty"

    val available: Boolean by lazy {
        try {
            System.loadLibrary("jxpty")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "libjxpty.so not available: ${t.message}")
            false
        }
    }

    external fun spawn(
        command: String,
        args: Array<String>,
        env: Array<String>,
        cwd: String,
        rows: Int,
        cols: Int
    ): Long

    /** Non-blocking. Returns bytes read, 0 for none, -1 when the pty closed. */
    external fun read(handle: Long, buffer: ByteArray): Int

    external fun write(handle: Long, data: ByteArray): Int

    external fun resize(handle: Long, rows: Int, cols: Int)

    external fun close(handle: Long)

    /** Waits briefly for the child. Returns the exit code, or -1 if still alive. */
    external fun waitFor(handle: Long, timeoutMs: Int): Int

    external fun signal(handle: Long, signal: Int): Int
}
