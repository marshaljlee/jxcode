package com.jxcode.android.terminal

import android.content.Context
import android.os.Build
import com.jxcode.android.LooperRuntime
import com.jxcode.android.NodeRuntime
import com.jxcode.android.SandboxHome
import java.io.File

/**
 * The environment handed to every process spawned in the pty.
 *
 * The isolation model is the macOS build's: override `$HOME` rather than
 * setting a per-tool config directory, because oh-my-pi and Jules document no
 * config-directory variable at all. On Android the app's `filesDir` is already
 * private to the uid, so the sandbox is narrower than what macOS had to
 * construct — but `getpwuid()` still returns the real home when `$HOME` is
 * overridden, which is why the config directories are also pinned explicitly.
 */
object SandboxEnvironment {

    /** Directories a spawned shell can search for programs, sandbox-first. */
    fun path(context: Context): List<String> {
        val home = SandboxHome.home(context)
        val nativeLibDir = File(context.applicationInfo.nativeLibraryDir)
        return buildList {
            add(File(home, ".npm-global/bin").absolutePath)
            add(File(home, ".local/bin").absolutePath)
            // Looper's own bin directory, which is where `looper daemon install`
            // puts the managed daemon. Ahead of nativeLibraryDir so the managed
            // copy wins over the bundled one once it has been installed.
            add(LooperRuntime.home(context).absolutePath + "/bin")
            add(nativeLibDir.absolutePath)
            // Termux's prefix, if the user has it: its Node is the easiest way
            // to get a real agent CLI running on a non-rooted phone.
            //
            // It is listed but almost never usable. Android seals another
            // app's data directory, so /data/data/com.termux is unreadable and
            // unsearchable from here — `ls` on it returns "Permission denied",
            // and Termux's RUN_COMMAND bridge is refused unless the user turns
            // on external execution inside Termux itself. Nothing in this app
            // should assume a path below it resolves.
            add("/data/data/com.termux/files/usr/bin")
            add("/system/bin")
            add("/system/xbin")
            add("/vendor/bin")
            add("/product/bin")
        }
    }

    fun build(
        context: Context,
        routerURL: String? = null,
        model: String? = null,
        contextLength: Int? = null,
        extra: Map<String, String> = emptyMap()
    ): Array<String> {
        val home = SandboxHome.home(context).absolutePath
        val root = SandboxHome.root(context).absolutePath
        val tmp = File(context.cacheDir, "sandbox-tmp").apply { mkdirs() }.absolutePath

        val environment = linkedMapOf(
            "HOME" to home,
            "PATH" to path(context).joinToString(":"),
            // The bundled node lives in nativeLibraryDir alongside the shared
            // libraries it was linked against (libcrypto.so.3, libicuuc.so.78,
            // …). Nothing was copied into the sandbox, so this is what makes
            // those resolve; their baked-in Termux RUNPATH never exists here.
            "LD_LIBRARY_PATH" to NodeRuntime.libraryDir(context),
            // Trust store for the bundled curl; Node and OpenSSL read the
            // same variable rather than a compiled-in default.
            "SSL_CERT_FILE" to NodeRuntime.caBundle(context).absolutePath,
            "CURL_CA_BUNDLE" to NodeRuntime.caBundle(context).absolutePath,
            "NODE_EXTRA_CA_CERTS" to NodeRuntime.caBundle(context).absolutePath,
            "TMPDIR" to tmp,
            "TEMP" to tmp,
            "TMP" to tmp,
            // 256 colour is what TUIs negotiate for; without it Claude Code
            // falls back to a monochrome theme that is hard to read.
            "TERM" to "xterm-256color",
            "COLORTERM" to "truecolor",
            "LANG" to "C.UTF-8",
            "LC_ALL" to "C.UTF-8",
            "SHELL" to "/system/bin/sh",
            "PWD" to home,
            // npm installs into the sandbox instead of a system prefix.
            "npm_config_prefix" to File(home, ".npm-global").absolutePath,
            "npm_config_cache" to File(home, ".npm").absolutePath,
            "npm_config_userconfig" to File(home, ".npmrc").absolutePath,
            // Config dirs: $HOME alone is not enough, because getpwuid()
            // resolves the real home regardless of $HOME.
            "CLAUDE_CONFIG_DIR" to File(home, ".claude").absolutePath,
            "CODEX_HOME" to File(home, ".codex").absolutePath,
            "GEMINI_CONFIG_DIR" to File(home, ".gemini").absolutePath,
            "XDG_CONFIG_HOME" to File(home, ".config").absolutePath,
            "XDG_DATA_HOME" to File(home, ".local/share").absolutePath,
            "XDG_CACHE_HOME" to File(home, ".cache").absolutePath,
            "JXCODE_ROOT" to root,
            "JXCODE_PLATFORM" to "android-${Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"}",
            // Looper's own runtime paths. These are the names its config
            // loader actually reads (internal/config/load.go), and pinning all
            // four is what stops `looper status` from reporting "not writable"
            // and refusing every subcommand: the app's $HOME is a fresh
            // directory that does not yet contain the layout it defaults to.
            "LOOPER_CONFIG" to File(LooperRuntime.home(context), "config.toml").absolutePath,
            "LOOPER_DB_PATH" to File(LooperRuntime.home(context), "looper.sqlite").absolutePath,
            "LOOPER_LOG_DIR" to File(LooperRuntime.home(context), "logs").absolutePath,
            "LOOPER_WORKING_DIRECTORY" to File(LooperRuntime.home(context), "workspace").absolutePath
        )

        if (routerURL != null) {
            environment["ANTHROPIC_BASE_URL"] = routerURL
            environment["OPENAI_BASE_URL"] = "$routerURL/v1"
            // Both are set because agents differ in which they read; the router
            // ignores the value.
            environment["ANTHROPIC_AUTH_TOKEN"] = "jxcode-local"
            environment["OPENAI_API_KEY"] = "jxcode-local"
            environment["ANTHROPIC_API_KEY"] = "jxcode-local"
        }
        if (model != null) {
            environment["ANTHROPIC_MODEL"] = model
            environment["ANTHROPIC_DEFAULT_MODEL"] = model
            environment["OPENAI_MODEL"] = model
        }
        // Same trap the macOS build hit: Claude Code assumes a 200k window for
        // any model it does not recognise, so a local model loaded at 4k
        // overflows on the first request. The window is a fact about the
        // backend, and this is where a spawned agent hears it.
        if (contextLength != null && contextLength > 0) {
            environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = contextLength.toString()
        }

        environment.putAll(extra)
        return environment.map { "${it.key}=${it.value}" }.toTypedArray()
    }
}
