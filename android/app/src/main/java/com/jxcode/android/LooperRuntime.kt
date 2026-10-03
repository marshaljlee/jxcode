package com.jxcode.android

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Looper, bundled into the APK and run inside the sandbox.
 *
 * The CLI and daemon are cross-built from source by `native/build-looper.sh`
 * and ship as `libjxbin_looper.so` / `libjxbin_looperd.so`. They have to travel
 * as jniLibs for the reason every other bundled binary does: Android 10 and
 * later refuse to exec anything in an app's data directory, and
 * `nativeLibraryDir` is the one place execution is still allowed. The `.so`
 * suffix is not an accident — AGP drops jniLibs whose name does not end in it,
 * so the `bin_` namespace is what keeps `looper` and a hypothetical
 * `liblooper.so` from colliding.
 *
 * Looper writes its config, database, logs and worktrees under `$HOME`, so
 * every path it validates has to exist and be writable before it will run at
 * all — `looper status` on a bare environment reports four "not writable"
 * errors and refuses every subcommand, which looks like a broken binary rather
 * than a missing directory. [prepare] creates them.
 */
object LooperRuntime {

    private const val TAG = "JXCodeLooper"
    private const val STAMP = "looper.stamp"

    const val CLI_LIBRARY = "libjxbin_looper.so"
    const val DAEMON_LIBRARY = "libjxbin_looperd.so"

    /** Absolute path of the bundled CLI, or null when this APK has none. */
    fun cliBinary(context: Context): File? =
        File(context.applicationInfo.nativeLibraryDir, CLI_LIBRARY)
            .takeIf { it.exists() && it.canExecute() }

    /** Absolute path of the bundled daemon, or null when this APK has none. */
    fun daemonBinary(context: Context): File? =
        File(context.applicationInfo.nativeLibraryDir, DAEMON_LIBRARY)
            .takeIf { it.exists() && it.canExecute() }

    /** Where Looper keeps its own state, inside the sandbox `$HOME`. */
    fun home(context: Context): File = File(SandboxHome.home(context), ".looper")

    /**
     * Creates every directory Looper validates at startup.
     *
     * Called on every boot rather than once: the sandbox survives an app
     * upgrade, but nothing here is expensive enough that re-checking it is
     * worth the failure mode of a missing directory. Each path mirrors a field
     * in the config schema — the four names in Looper's own "not writable"
     * complaint are the database, the log directory, the daemon's working
     * directory, and the worktree root.
     */
    fun prepare(context: Context): Boolean {
        val cli = cliBinary(context) ?: run {
            Log.w(TAG, "no $CLI_LIBRARY in ${context.applicationInfo.nativeLibraryDir}")
            return false
        }
        val base = home(context)
        // The four names are the exact fields Looper validates before it will
        // run anything (internal/config): storage.dbPath's parent, the log
        // directory, the daemon working directory, and the worktree root. It
        // refuses *every* subcommand when any one is missing, so all four are
        // created together.
        val directories = listOf(
            base,
            File(base, "bin"),
            File(base, "logs"),
            File(base, "workspace"),
            File(base, "worktrees"),
            File(base, "backups")
        )
        var ok = true
        for (directory in directories) {
            if (!directory.exists() && !directory.mkdirs()) {
                Log.w(TAG, "could not create ${directory.absolutePath}")
                ok = false
            }
        }

        // A stamp naming the bundled build, so an app upgrade that changes the
        // binary does not leave a stale version behind claiming to be current.
        val version = stampFor(context)
        val stampFile = File(base, STAMP)
        val previous = runCatching { stampFile.readText() }.getOrNull()
        if (previous != version) {
            runCatching { stampFile.writeText(version) }
        }
        Log.i(TAG, "looper sandbox at ${base.absolutePath} (${cli.name}, stamp=$version)")
        return ok
    }

    private fun stampFor(context: Context): String = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        "${info.lastUpdateTime}:${cliBinary(context)?.length() ?: 0}"
    }.getOrDefault("unknown")

    /**
     * Whether both binaries are present. Reported in the doctor panel.
     *
     * The daemon is checked separately from the CLI because a partial bundle is
     * a real state: a build that ran `build-looper.sh` before the daemon
     * existed would otherwise look fine and fail only at `looper daemon start`.
     */
    fun isBundled(context: Context): Boolean =
        cliBinary(context) != null && daemonBinary(context) != null

    /** One-line summary for the doctor panel. */
    fun describe(context: Context): String {
        val cli = cliBinary(context) ?: return "not bundled in this APK"
        val daemon = if (daemonBinary(context) != null) " + daemon" else " (daemon missing)"
        return "looper + looperd$daemon bundled · ${cli.parent}"
    }
}