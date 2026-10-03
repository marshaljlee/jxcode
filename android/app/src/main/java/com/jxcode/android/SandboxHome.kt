package com.jxcode.android

import android.content.Context
import java.io.File

/**
 * The private `$HOME` every agent CLI inherits.
 *
 * JXCode on macOS overrides `$HOME` rather than setting a per-tool config
 * directory, because oh-my-pi (`~/.omp`) and Jules (`~/.jules`) document no
 * config-directory variable at all — `$HOME` is the only lever that exists.
 * The same reasoning holds here. On Android the app's `filesDir` is already
 * private to the uid, which JXCode had to construct by hand on macOS.
 */
object SandboxHome {

    const val ENV_ROOT = "env"

    /** `$HOME` handed to spawned processes. */
    fun home(context: Context): File = File(context.filesDir, "$ENV_ROOT/home")

    /** Everything the sandbox owns, `$HOME` included. */
    fun root(context: Context): File = File(context.filesDir, ENV_ROOT)

    /** Per-workspace directory, mirroring `SandboxPaths` on macOS. */
    fun workspace(context: Context, slug: String): File =
        File(root(context), "workspaces/$slug")

    fun ensure(context: Context): File {
        val home = home(context)
        File(home, ".config").mkdirs()
        File(home, ".local/bin").mkdirs()
        File(home, ".npm-global/bin").mkdirs()
        File(root(context), "workspaces").mkdirs()
        return home
    }
}
