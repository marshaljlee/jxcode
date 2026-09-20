package com.jxcode.android

import android.content.Context
import android.util.Log
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

        script(bin, "node", "exec \"${node.absolutePath}\" \"\$@\"\n")
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

    /** One-line summary for the doctor panel. */
    fun describe(context: Context): String {
        val node = nodeBinary(context) ?: return "not bundled in this APK"
        val parts = mutableListOf("node")
        if (File(modules(context), "npm/package.json").exists()) parts += "npm"
        if (curlBinary(context) != null) parts += "curl"
        return "${parts.joinToString(" + ")} bundled · ${node.parent}"
    }
}
