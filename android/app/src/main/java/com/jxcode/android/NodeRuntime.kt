package com.jxcode.android

import android.content.Context
import android.util.Log
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.zip.ZipInputStream

/**
 * The Node.js runtime that ships inside the APK.
 *
 * The binaries are *not* copied anywhere. Android 10 and later refuse to exec
 * code that lives in an app's data directory (W^X), so `libjxnode.so` and the
 * shared libraries it needs stay in `nativeLibraryDir` — the one place the
 * system still allows execution from — and are launched from there. What this
 * object does own is everything that is safe to write into the sandbox:
 *
 *   - npm, which is pure JavaScript, unpacked from an asset zip;
 *   - tiny `#!/system/bin/sh` wrappers in `$HOME/.local/bin` that exec the
 *     real binary by absolute path, because `libjxnode.so` is not a name any
 *     shell or agent CLI would ever look for.
 *
 * The library search path is set in [SandboxEnvironment] rather than here:
 * `LD_LIBRARY_PATH=nativeLibraryDir` is what lets Node find libcrypto.so.3
 * and friends without any of them being moved.
 */
object NodeRuntime {

    private const val TAG = "JXCodeRuntime"

    // `lib*.so` is forced by the APK, and bundled executables carry a `bin_`
    // prefix so that `bin/curl` and `libcurl.so` cannot collide on one name.
    const val NODE_LIBRARY = "libjxbin_node.so"
    const val CURL_LIBRARY = "libjxbin_curl.so"

    private const val NPM_ZIP = "runtime/npm.zip"
    private const val CA_BUNDLE = "runtime/ca-bundle.crt"
    private const val STAMP = "npm.stamp"

    /** Absolute path of the bundled node, or null when this APK has none. */
    fun nodeBinary(context: Context): File? =
        File(context.applicationInfo.nativeLibraryDir, NODE_LIBRARY)
            .takeIf { it.exists() && it.canExecute() }

    /** Absolute path of the bundled curl, or null when this APK has none. */
    fun curlBinary(context: Context): File? =
        File(context.applicationInfo.nativeLibraryDir, CURL_LIBRARY)
            .takeIf { it.exists() && it.canExecute() }

    /** CA bundle inside the sandbox, once [ensure] has unpacked it. */
    fun caBundle(context: Context): File = File(root(context), "etc/tls/cert.pem")

    /** The library directory node must search at runtime. */
    fun libraryDir(context: Context): String = context.applicationInfo.nativeLibraryDir

    /** Prefix inside the sandbox: `$JXCODE_ROOT/usr`. */
    fun root(context: Context): File = File(SandboxHome.root(context), "usr")

    private fun modules(context: Context): File = File(root(context), "lib/node_modules")

    /**
     * Installs npm and the wrappers. Cheap after the first run: the stamp
     * records the asset size and the package's update time, so nothing is
     * unpacked again until the app is upgraded.
     */
    fun ensure(context: Context): Boolean {
        val node = nodeBinary(context)
        if (node == null) {
            Log.w(TAG, "no $NODE_LIBRARY in ${context.applicationInfo.nativeLibraryDir}")
            return false
        }
        val home = SandboxHome.ensure(context)
        File(home, ".local/bin").mkdirs()

        val root = root(context)
        val stampFile = File(root, STAMP)
        val stamp = stampFor(context)
        if (!stampFile.exists() || stampFile.readText() != stamp) {
            expandNpm(context, modules(context))
            copyCaBundle(context)
            runCatching { stampFile.writeText(stamp) }
        }
        writeWrappers(context, node, File(modules(context), "npm"))
        return true
    }

    private fun copyCaBundle(context: Context) {
        val target = caBundle(context)
        if (target.exists()) return
        runCatching {
            target.parentFile?.mkdirs()
            context.assets.open(CA_BUNDLE).use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
        }.onFailure { Log.w(TAG, "could not unpack the CA bundle", it) }
    }

    private fun stampFor(context: Context): String {
        val size = runCatching {
            context.assets.openFd(NPM_ZIP).use { it.length }
        }.getOrDefault(-1L)
        val updated = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        }.getOrDefault(0L)
        return "$size:$updated"
    }

    private fun expandNpm(context: Context, modules: File) {
        modules.mkdirs()
        val started = System.currentTimeMillis()
        var files = 0
        runCatching {
            context.assets.open(NPM_ZIP).use { raw ->
                ZipInputStream(raw.buffered()).use { zip ->
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        val target = File(modules, entry.name)
                        if (!target.canonicalPath.startsWith(modules.canonicalPath + File.separator)) {
                            continue
                        }
                        if (entry.isDirectory) {
                            target.mkdirs()
                            continue
                        }
                        target.parentFile?.mkdirs()
                        target.outputStream().use { out -> zip.copyTo(out) }
                        files++
                    }
                }
            }
        }.onFailure { Log.w(TAG, "npm expansion failed", it) }
        Log.i(TAG, "expanded $files npm files in ${System.currentTimeMillis() - started}ms")
    }

    private fun writeWrappers(context: Context, node: File, npm: File) {
        val bin = File(SandboxHome.home(context), ".local/bin")
        val prefix = File(root(context), "lib/node_modules").absolutePath

        // `node` must resolve to the real binary AND be exec-able from the
        // sandbox. A shebang wrapper here fails Android 10+'s noexec mount — but
        // a symlink to nativeLibraryDir/libjxbin_node.so resolves to an
        // exec-allowed mount, and the kernel follows it on exec. `which node`
        // then finds it on PATH and `node ./index.cjs` (the way every npm
        // lifecycle script invokes it) runs.
        val nodeLink = File(bin, "node")
        runCatching {
            if (nodeLink.exists() || java.nio.file.Files.isSymbolicLink(nodeLink.toPath())) {
                nodeLink.delete()
            }
            java.nio.file.Files.createSymbolicLink(nodeLink.toPath(), node.toPath())
        }.onFailure { Log.w(TAG, "could not symlink node → ${node.absolutePath}", it) }

        // npm and npx are invoked directly as `node <cli>.js` (see
        // installInvocation), so the wrappers are not needed for our install
        // path. Keep them anyway for anything else that calls `npm` by name;
        // if the noexec mount still bites there too, callers should switch to
        // the absolute form.
        script(
            bin, "npm",
            "exec \"${node.absolutePath}\" \"$prefix/npm/bin/npm-cli.js\" \"\$@\"\n"
        )
        script(
            bin, "npx",
            "exec \"${node.absolutePath}\" \"$prefix/npm/bin/npx-cli.js\" \"\$@\"\n"
        )
        curlBinary(context)?.let { curl ->
            script(bin, "curl", "exec \"${curl.absolutePath}\" \"\$@\"\n")
        }
    }

    private fun script(directory: File, name: String, body: String) {
        val file = File(directory, name)
        runCatching {
            file.writeText("#!/system/bin/sh\n$body")
            file.setExecutable(true, false)
        }.onFailure { Log.w(TAG, "could not write ${file.absolutePath}", it) }
    }

    /**
     * Rewrites `#!/usr/bin/env node` shebangs to point at the bundled node.
     *
     * npm writes `#!/usr/bin/env node` into every global bin shim it creates,
     * and Android has no `/usr`, so an agent installed with `npm i -g` fails
     * with ENOENT the moment the shell tries to run it. Pointing the shebang
     * straight at the binary is enough: node takes the script path as argv[1].
     */
    fun fixShims(context: Context) {
        val node = nodeBinary(context) ?: return
        val home = SandboxHome.home(context)
        for (directory in listOf(File(home, ".npm-global/bin"), File(home, ".local/bin"))) {
            for (file in directory.listFiles() ?: continue) {
                if (!file.isFile) continue
                val text = runCatching { file.readText() }.getOrNull() ?: continue
                if (!text.startsWith("#!")) continue
                val first = text.lineSequence().first()
                val words = first.removePrefix("#!").trim().split(Regex("\\s+"))
                if (words.firstOrNull()?.endsWith("/env") != true) continue
                if ("node" !in words) continue
                runCatching {
                    file.writeText("#!${node.absolutePath}\n" + text.substringAfter('\n'))
                }.onFailure { Log.w(TAG, "could not fix ${file.name}", it) }
            }
        }
    }

    // MARK: - Running things without exec'ing them
    //
    // `script()` above writes wrappers, and wrappers are what a normal shell
    // session wants — but **a wrapper cannot be executed here**. The file lives
    // under the app's data directory, and Android refuses to exec anything
    // there (W^X): `npm` fails with `Permission denied` even though the chmod
    // succeeded. The binary in `nativeLibraryDir` *is* executable, so the way
    // to run a JS entry point is to exec node and hand it the script as argv,
    // rather than exec the script and let its shebang find node.

    /** npm's own CLI entry point, once [ensure] has unpacked it. */
    fun npmCli(context: Context): File? =
        File(modules(context), "npm/bin/npm-cli.js").takeIf { it.exists() }

    /**
     * The command that installs `packageName` globally, or `null` when npm is
     * not available.
     *
     * Invoked as `<node> <npm-cli.js> i -g …` rather than as the `npm`
     * wrapper, for the reason above.
     */
    fun installInvocation(context: Context, packageName: String): String? {
        val node = nodeBinary(context) ?: return null
        val cli = npmCli(context) ?: return null
        return "'${node.absolutePath}' '${cli.absolutePath}' i -g --no-audit --no-fund '$packageName'"
    }

    /**
     * A JS entry point that can actually be run: `[node, entry]`.
     *
     * Resolved from the installed package's own `bin` map, because the shim npm
     * drops in `.npm-global/bin` is a shebang script in the sandbox and so is
     * not executable. Returns `null` when the package is not installed, or when
     * its `bin` is not JavaScript.
     *
     * A `null` here is meaningful rather than a failure to fall back from: some
     * agents are not JavaScript at all. `@anthropic-ai/claude-code` and
     * `opencode-ai` ship platform-native binaries pulled in by a postinstall
     * script, and their published optional dependencies cover darwin/linux/
     * win32 only — there is no Android build, and a glibc `linux-arm64` binary
     * will not run against Bionic regardless. Those two can never launch here.
     */
    fun agentLaunch(context: Context, packageName: String, binName: String): Pair<String, String>? {
        val node = nodeBinary(context) ?: return null
        val home = SandboxHome.home(context)
        val roots = listOf(
            File(home, ".npm-global/lib/node_modules"),
            File(root(context), "lib/node_modules")
        )
        for (moduleRoot in roots) {
            val packageDir = File(moduleRoot, packageName)
            val manifest = File(packageDir, "package.json")
            if (!manifest.exists()) continue
            val entry = binEntry(manifest, binName) ?: continue
            // Only hand node something that is JavaScript. A `bin` may point at
            // a native binary or at a shell stub — `claude` and `opencode` both
            // ship a `.exe` placeholder that just prints an install error — and
            // feeding either to node produces a syntax error instead of the
            // honest "this cannot run on Android" message.
            if (!entry.substringAfterLast('.').lowercase()
                .let { it == "js" || it == "cjs" || it == "mjs" }
            ) continue
            val resolved = File(packageDir, entry)
            if (!resolved.exists()) continue
            return node.absolutePath to resolved.absolutePath
        }
        return null
    }

    /** The `bin` value for `binName` in a package manifest. */
    private fun binEntry(manifest: File, binName: String): String? {
        val text = runCatching { manifest.readText() }.getOrNull() ?: return null
        return runCatching {
            val json = Json.parseToJsonElement(text).jsonObject
            when (val bin = json["bin"]) {
                is JsonPrimitive -> bin.content
                is JsonObject -> bin[binName]?.jsonPrimitive?.content
                else -> null
            }
        }.getOrNull()
    }

    /** One-line summary for the doctor panel. */
    fun describe(context: Context): String {
        val node = nodeBinary(context) ?: return "not bundled in this APK"
        val parts = mutableListOf("node")
        if (File(modules(context), "npm/package.json").exists()) parts += "npm"
        if (curlBinary(context) != null) parts += "curl"
        return "${parts.joinToString(" + ")} bundled · ${node.parent}"
    }
}
