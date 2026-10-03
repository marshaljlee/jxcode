package com.jxcode.android

import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Environment
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jxcode.android.data.GGUFModelInfo
import com.jxcode.android.data.GGUFReader
import com.jxcode.android.data.ModelCatalog
import com.jxcode.android.data.Provider
import com.jxcode.android.data.ProviderKind
import com.jxcode.android.data.ProviderStore
import com.jxcode.android.llama.LlamaBridge
import com.jxcode.android.router.ModelRouter
import com.jxcode.android.router.RouterService
import com.jxcode.android.terminal.SandboxEnvironment
import com.jxcode.android.terminal.TerminalBuffer
import com.jxcode.android.terminal.TerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

data class DoctorCheck(val name: String, val ok: Boolean, val detail: String)

/**
 * A `.gguf` found on the device, with whatever its header says about it.
 *
 * `info` is null when the file would not parse. A model card is a nicety:
 * llama.cpp still loads a file this reader does not understand, so a null here
 * means "fall back to defaults", never "refuse to load".
 */
data class LocalModel(
    val file: File,
    val sizeBytes: Long,
    val info: GGUFModelInfo? = null
)

/**
 * One place for the state the UI needs.
 *
 * The router is started eagerly in `init` because every agent CLI inherits its
 * base URL from the environment at spawn time: starting it later would mean a
 * terminal launched before the router existed could never reach it.
 */
class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val app: Context get() = getApplication<Application>().applicationContext

    val router = ModelRouter(app)
    private val store = ProviderStore(app)

    private val _providers = MutableStateFlow(store.all())
    val providers: StateFlow<List<Provider>> = _providers.asStateFlow()

    private val _selectedProvider = MutableStateFlow<Provider?>(null)
    val selectedProvider: StateFlow<Provider?> = _selectedProvider.asStateFlow()

    private val _selectedModel = MutableStateFlow<String?>(null)
    val selectedModel: StateFlow<String?> = _selectedModel.asStateFlow()

    private val _fetchMessage = MutableStateFlow<String?>(null)
    val fetchMessage: StateFlow<String?> = _fetchMessage.asStateFlow()

    private val _models = MutableStateFlow<List<String>>(emptyList())
    val models: StateFlow<List<String>> = _models.asStateFlow()

    private val _localModels = MutableStateFlow<List<LocalModel>>(emptyList())
    val localModels: StateFlow<List<LocalModel>> = _localModels.asStateFlow()

    private val _llamaState = MutableStateFlow("not loaded")
    val llamaState: StateFlow<String> = _llamaState.asStateFlow()

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()

    private val _runtime = MutableStateFlow("checking bundled runtime…")
    val runtime: StateFlow<String> = _runtime.asStateFlow()

    private val _runtimeReady = MutableStateFlow(false)
    val runtimeReady: StateFlow<Boolean> = _runtimeReady.asStateFlow()

    private val _looperState = MutableStateFlow("checking bundled looper…")
    val looperState: StateFlow<String> = _looperState.asStateFlow()

    private val _looperReady = MutableStateFlow(false)
    val looperReady: StateFlow<Boolean> = _looperReady.asStateFlow()

    val terminalBuffer = TerminalBuffer(80, 24)
    val session = TerminalSession(terminalBuffer, viewModelScope)

    private val _spawned = MutableStateFlow(false)
    val spawned: StateFlow<Boolean> = _spawned.asStateFlow()

    private val _spawnTarget = MutableStateFlow("shell")
    val spawnTarget: StateFlow<String> = _spawnTarget.asStateFlow()

    // MARK: - Agents

    /**
     * Which agents are runnable right now.
     *
     * Resolved from the sandbox rather than remembered, because an agent can be
     * installed by hand in the terminal and the launcher has to notice. The
     * macOS app reads the same fact off the sandbox `PATH`.
     */
    private val _installedAgents = MutableStateFlow<Set<String>>(emptySet())
    val installedAgents: StateFlow<Set<String>> = _installedAgents.asStateFlow()

    private val _installingAgentIDs = MutableStateFlow<Set<String>>(emptySet())
    val installingAgentIDs: StateFlow<Set<String>> = _installingAgentIDs.asStateFlow()

    private val _installFailures = MutableStateFlow<Map<String, String>>(emptyMap())
    val installFailures: StateFlow<Map<String, String>> = _installFailures.asStateFlow()

    private val _preinstallStarted = MutableStateFlow(false)
    private val _preinstallProgress = MutableStateFlow("")
    val preinstallProgress: StateFlow<String> = _preinstallProgress.asStateFlow()
    private val _preinstallDone = MutableStateFlow(false)
    val preinstallDone: StateFlow<Boolean> = _preinstallDone.asStateFlow()

    private val _sandboxOk = MutableStateFlow(false)
    val sandboxOk: StateFlow<Boolean> = _sandboxOk.asStateFlow()

    init {
        viewModelScope.launch(Dispatchers.IO) {
            // Before anything else: unpack npm and write the node/npm/npx
            // wrappers, so a shell started a moment later already has them on
            // PATH. It only touches the sandbox, not the binaries.
            val runtimeOk = runCatching { NodeRuntime.ensure(app) }.getOrDefault(false)
            _runtime.value = if (runtimeOk) NodeRuntime.describe(app) else "bundled runtime unavailable"
            _runtimeReady.value = true
            // Looper's directory layout before anything tries to run it: it
            // validates four paths at startup and refuses every subcommand when
            // any of them is missing, which looks exactly like a broken binary.
            val looperOk = runCatching { LooperRuntime.prepare(app) }.getOrDefault(false)
            _looperState.value = if (looperOk) {
                LooperRuntime.describe(app)
            } else {
                "not bundled in this APK"
            }
            _looperReady.value = looperOk
            runCatching { router.start() }
            // Keeps the process (and any loaded GGUF) alive when the UI leaves.
            RouterService.start(app, "Router on ${router.baseURL ?: "loopback"}")
            refreshLocalModels()
            _sandboxOk.value = SandboxHome.home(app).exists()
            refreshInstalledAgents()
        }
        viewModelScope.launch {
            while (true) {
                _log.value = router.log()
                delay(1000)
            }
        }
        // No shell is spawned here, and that is deliberate now that the
        // dashboard is the front door: the macOS app opens a terminal once an
        // agent has been launched, not before. Spawning one eagerly would put
        // a pty behind a dashboard nobody had asked for.
    }

    // MARK: - Providers

    fun addProvider(
        name: String,
        baseURL: String,
        kind: ProviderKind,
        apiKey: String,
        contextLength: Int? = null
    ) {
        val provider = Provider(name = name, baseURL = baseURL, kind = kind, contextLength = contextLength)
        val stored = store.add(provider)
        if (apiKey.isNotBlank()) store.setApiKey(stored, apiKey.trim())
        _providers.value = store.all()
    }

    fun removeProvider(id: String) {
        store.remove(id)
        _providers.value = store.all()
        if (_selectedProvider.value?.id == id) select(null, null)
    }

    fun select(provider: Provider?, model: String?) {
        _selectedProvider.value = provider
        _selectedModel.value = model ?: provider?.models?.firstOrNull()
        router.update(provider, _selectedModel.value)
        if (model == null && provider != null) fetchModels(provider)
    }

    fun fetchModels(provider: Provider) {
        viewModelScope.launch {
            _fetchMessage.value = "fetching models…"
            val result = ModelCatalog.fetch(provider, store.apiKey(provider))
            _models.value = result.ids
            _fetchMessage.value = result.error ?: result.note ?: "${result.ids.size} model(s)"
            if (result.ids.isNotEmpty()) {
                val updated = store.add(provider.copy(models = result.ids))
                _providers.value = store.all()
                if (_selectedProvider.value?.id == provider.id) {
                    _selectedProvider.value = updated
                    if (_selectedModel.value == null) select(updated, result.ids.first())
                }
            }
        }
    }

    // MARK: - Local GGUF

    /**
     * Every `.gguf` this app can actually read.
     *
     * Every root here is app-owned, and that is the point. An earlier version
     * also scanned `/storage/emulated/0/Download` and `/storage/emulated/0/Models`,
     * which has not worked since Android 11: scoped storage returns an empty
     * listing for those paths instead of an error, so the scan silently found
     * nothing while the screen still told the user to drop a model into
     * Download. The document picker is the path that works, and it copies into
     * the sandbox — which is where `$JXCODE_ROOT/models` comes in.
     */
    fun refreshLocalModels() {
        viewModelScope.launch(Dispatchers.IO) {
            val roots = listOfNotNull(
                File(SandboxHome.root(app), "models"),
                app.getExternalFilesDir(null),
                app.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ).filter { it.exists() }

            val found = roots.flatMap { root ->
                (root.listFiles { file -> file.extension.equals("gguf", ignoreCase = true) } ?: emptyArray())
                    .map { file ->
                        // Read the header once, here: it carries the context
                        // window the model gets opened with, and a model card
                        // should not cost a file read on every load.
                        LocalModel(file, file.length(), GGUFReader.read(file))
                    }
            }.distinctBy { it.file.absolutePath }.sortedByDescending { it.sizeBytes }

            _localModels.value = found
        }
    }

    /**
     * Copies a picked .gguf into the sandbox.
     *
     * The picker returns a content URI and llama.cpp needs a real file path;
     * copying is the reliable translation, and it also brings the model inside
     * the app's own storage where no extra permission is needed to read it.
     */
    fun importModel(uri: Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            val directory = File(SandboxHome.root(app), "models").apply { mkdirs() }
            val raw = uri.lastPathSegment?.substringAfterLast('/') ?: "model.gguf"
            val safe = raw.filter { it.isLetterOrDigit() || it in setOf('.', '-', '_') }
                .ifBlank { "model.gguf" }
            val destination = File(directory, safe)
            val copied = runCatching {
                app.contentResolver.openInputStream(uri)?.use { input ->
                    destination.outputStream().use { output -> input.copyTo(output) }
                }
                destination.length()
            }.getOrDefault(0L)
            refreshLocalModels()
            _llamaState.value = if (copied > 0) "imported ${destination.name}" else "import failed: $uri"
        }
    }

    fun loadLocalModel(model: LocalModel) {
        viewModelScope.launch(Dispatchers.IO) {
            val requested = contextBudget(model)
            val declared = model.info?.contextLength
            _llamaState.value = "loading ${model.file.name}…"
            val ok = LlamaBridge.load(model.file.absolutePath, contextSize = requested)
            _llamaState.value = when {
                !ok -> "failed: ${LlamaBridge.lastError}"
                // Say so when the budget and the model disagree. A silent
                // clamp is how a 32k model gets served short and nobody
                // notices until a long file fails to summarise.
                declared != null && requested < declared ->
                    "loaded: ${model.file.name} · $requested ctx (model declares $declared)"
                else -> "loaded: ${model.file.name} · $requested ctx"
            }

            if (ok) {
                // The window is whatever the model was opened with — the
                // backends' own answer, not a prediction.
                val context = LlamaBridge.loadedContextSize.takeIf { it > 0 }
                val provider = Provider.local(
                    router.port ?: ModelRouter.DEFAULT_PORT,
                    model.file.name,
                    context
                )
                val stored = store.add(provider)
                _providers.value = store.all()
                select(stored, model.file.name)
            }
        }
    }

    /**
     * The window to open a model with.
     *
     * The model's own number where the header provides one — a constant here
     * is wrong in both directions, serving a 32k model short and opening a
     * 2048-token model at twice its window. It is then clamped, because the KV
     * cache is allocated up front and a 128k context on a phone is an
     * out-of-memory kill rather than a slow request. The ceiling is a budget,
     * not a fact about the model, which is why [loadLocalModel] reports the
     * disagreement instead of hiding it.
     */
    private fun contextBudget(model: LocalModel): Int {
        val declared = model.info?.contextLength ?: return DEFAULT_CONTEXT_TOKENS
        return declared.coerceIn(MIN_CONTEXT_TOKENS, MAX_CONTEXT_TOKENS)
    }

    private companion object {
        /** Only reached when the header could not be read at all. */
        const val DEFAULT_CONTEXT_TOKENS = 4096
        const val MIN_CONTEXT_TOKENS = 512
        /**
         * Deliberately below what most models declare: a phone's usable RAM is
         * far less than the number on the box, and the KV cache is what runs
         * out first.
         */
        const val MAX_CONTEXT_TOKENS = 8192

        /**
         * How long the preinstall watcher waits before declaring the pass
         * finished. Generous, because a phone on a slow connection installing
         * six CLIs can legitimately take many minutes; the watcher stopping
         * early would leave cards stuck on "installing" with nothing to retry.
         */
        const val PREINSTALL_TIMEOUT_MS = 30 * 60 * 1000L
    }

    fun unloadLocalModel() {
        LlamaBridge.unload()
        _llamaState.value = "not loaded"
    }

    // MARK: - Terminal

    /**
     * Where an agent's binary actually is, or null if it is not installed.
     *
     * Every agent here is a Node CLI, so the two places one can land are the
     * sandbox's global npm bin and anything on the rebuilt `PATH`. `shell` is
     * the one agent that always resolves, because it is the platform shell.
     *
     * Keyed by id rather than by command so "shell" — whose command is a full
     * path, not a binary name — does not get looked up as a file called
     * `/system/bin/sh` inside the npm bin directory.
     */
    fun agentCommand(id: String): String? {
        if (id == "shell") return "/system/bin/sh"
        val direct = File(File(SandboxHome.home(app), ".npm-global/bin"), id)
        if (direct.exists() && direct.canExecute()) return direct.absolutePath
        return resolveOnPath(id)
    }

    fun refreshInstalledAgents() {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { NodeRuntime.fixShims(app) }
            val found = com.jxcode.android.data.AgentRegistry.builtIns
                .filter { isLaunchable(it.id) }
                .map { it.id }
                .toSet()
            _installedAgents.value = found
            // An install that has landed is no longer in flight. Nothing else
            // clears this set, so without the line a card would read
            // "installing" forever after a successful install.
            _installingAgentIDs.value = _installingAgentIDs.value - found
        }
    }

    /**
     * Opens an agent, installing it first if it is missing.
     *
     * The install runs *inside* the terminal rather than behind a spinner:
     * npm's output is long and occasionally interactive, and a terminal that
     * shows it is more honest than a progress value invented here. The agent is
     * exec'd afterwards, so the session you land in is the agent rather than
     * the shell that installed it.
     */
    /**
     * The npm package an agent is installed from, or `null`.
     *
     * Taken from the agent's own `installCommand` rather than kept in a second
     * table, so the two cannot drift: whatever the card says it will install is
     * what gets installed. A bundled agent has no package — it is already in the
     * APK — so it answers `null` here and is never sent to npm.
     */
    private fun npmPackageOf(id: String): String? {
        val agent = com.jxcode.android.data.AgentRegistry.builtIns.firstOrNull { it.id == id }
            ?: return null
        if (agent.bundled) return null
        return agent.installCommand?.trim()?.split(Regex("\\s+"))?.lastOrNull()
    }

    /**
     * Whether this agent can be *launched*, which is not the same question as
     * whether its package is present.
     *
     * A present package whose `bin` is a native binary is still not launchable
     * here — see `NodeRuntime.agentLaunch`.
     */
    private fun isLaunchable(id: String): Boolean {
        if (id == "shell") return true
        if (id == "looper") return LooperRuntime.isBundled(app)
        val packageName = npmPackageOf(id) ?: return false
        return NodeRuntime.agentLaunch(app, packageName, id) != null
    }

    /**
     * Installs everything that is missing, in the background, before the user
     * taps anything.
     *
     * This is the whole point of the change: a card that says "install" and
     * only then does the work makes the user do two things to reach an agent,
     * and on a phone the wait is long enough to matter. So the work moves to
     * first launch, where it can overlap with the runtime being unpacked, and
     * the card becomes a statement of fact ("ready") rather than a button.
     *
     * Why it is a shell loop rather than one npm call per agent: npm's output
     * is long and occasionally interactive, and the terminal already exists to
     * show it. A single session also means one npm cache and one `node_modules`
     * tree, which is what keeps six installs from racing each other into a
     * corrupt prefix.
     *
     * Bundled agents are skipped — there is nothing to install for them — and
     * so is anything already launchable, so this is cheap to call repeatedly.
     */
    fun preinstallAll() {
        if (_preinstallStarted.value) return
        _preinstallStarted.value = true

        viewModelScope.launch(Dispatchers.IO) {
            // npm has to exist before anything can be installed into it, and
            // NodeRuntime.ensure is what unpacks it.
            val runtimeOk = runCatching { NodeRuntime.ensure(app) }.getOrDefault(false)
            if (!runtimeOk) {
                _preinstallProgress.value = "npm unavailable — cannot install agents"
                _preinstallDone.value = true
                return@launch
            }
            LooperRuntime.prepare(app)
            runCatching { NodeRuntime.fixShims(app) }

            val pending = com.jxcode.android.data.AgentRegistry.builtIns
                .filter { it.installCommand != null && !it.bundled }
                .filter { !isLaunchable(it.id) }
            if (pending.isEmpty()) {
                _preinstallProgress.value = "all agents ready"
                _preinstallDone.value = true
                refreshInstalledAgents()
                return@launch
            }

            val packages = pending.mapNotNull { npmPackageOf(it.id) }
            val byPackage = pending.associateBy { npmPackageOf(it.id) }

            // One script, one session. Each package installs and then records
            // itself, so the progress line reflects reality rather than a
            // counter that assumes success. `|| true` keeps one failure from
            // aborting the rest — a card that fails is recoverable, a card that
            // never gets attempted because the one before it failed is not.
            val script = buildString {
                append("set -e\n")
                packages.forEach { packageName ->
                    append("echo '>>> installing $packageName'\n")
                    append(runCatching { NodeRuntime.installInvocation(app, packageName) }
                        .getOrNull() ?: "true")
                    append(" || echo '>>> FAILED $packageName'\n")
                    append("echo '>>> done $packageName'\n")
                }
                append("echo '>>> preinstall complete'\n")
                append("exec /system/bin/sh\n")
            }

            _preinstallProgress.value = "installing ${packages.size} agent(s)…"
            spawnShellCommand(script, target = "preinstall")
            watchPreinstall(byPackage.keys)
        }
    }

    /**
     * Follows a preinstall session and reports how it went.
     *
     * Ends on the marker line the script prints rather than on process exit,
     * because the script ends in `exec /system/bin/sh` to keep a pty on screen
     * for the user — so the session deliberately does not exit, and waiting for
     * an exit code would hang here forever.
     */
    private fun watchPreinstall(packages: Set<String?>) {
        viewModelScope.launch(Dispatchers.IO) {
            val deadline = System.currentTimeMillis() + PREINSTALL_TIMEOUT_MS
            while (System.currentTimeMillis() < deadline) {
                delay(1000)
                // Re-resolve from the sandbox rather than trusting the marker:
                // `refreshInstalledAgents` already repairs the shebangs, and
                // this is the same check the badge uses, so the two cannot
                // disagree about what is installed.
                refreshInstalledAgents()

                val failures = _installFailures.value
                val done = com.jxcode.android.data.AgentRegistry.builtIns
                    .filter { it.installCommand != null && !it.bundled }
                val ready = done.count { isLaunchable(it.id) }

                _preinstallProgress.value = "$ready of ${done.size} agents ready"

                if (session.exitCode != null) {
                    _preinstallProgress.value = "preinstall stopped (exit ${session.exitCode})"
                    _preinstallDone.value = true
                    return@launch
                }
                // Every installable agent accounted for, or a failure was
                // booked: either way there is nothing left to wait for.
                val unaccounted = done.filter { it.installCommand != null }
                    .filter { !isLaunchable(it.id) }
                    .filter { failures[it.id] == null }
                if (unaccounted.isEmpty()) {
                    _preinstallProgress.value = "$ready of ${done.size} agents ready"
                    _preinstallDone.value = true
                    return@launch
                }
            }
            _preinstallProgress.value = "preinstall still running — tap an agent to see its output"
            _preinstallDone.value = true
        }
    }

    fun launchAgent(agent: com.jxcode.android.data.AgentDefinition) {
        if (isLaunchable(agent.id)) {
            spawn(agent.id)
            return
        }
        val packageName = npmPackageOf(agent.id)
        val install = packageName?.let { NodeRuntime.installInvocation(app, it) }
            ?: agent.installCommand
        if (install == null) {
            spawn(agent.id)
            return
        }
        _installingAgentIDs.value = _installingAgentIDs.value + agent.id
        _installFailures.value = _installFailures.value - agent.id
        // The install runs alone rather than as `<install> && exec <agent>`:
        // the agent's entry point is not known until npm has laid the package
        // down, and a shim path baked in now would not be executable anyway.
        // `watchInstall` opens the agent once it resolves.
        spawnShellCommand(install, target = agent.id)
        watchInstall(agent.id)
    }

    /**
     * Watches an install that is running inside the terminal and reports what
     * actually happened.
     *
     * Without this the card is stuck: nothing observes the install, so a failed
     * one leaves the agent in `installing` forever and the card never offers a
     * retry. The two exits are deliberately different signals:
     *
     * - **The binary appearing** means success. The script ends in
     *   `exec <agent>`, so a successful install hands the pty straight to the
     *   agent and the process never exits — exit code is not a usable success
     *   signal here, and waiting for one would keep the card "installing" for
     *   as long as the user leaves the agent open.
     * - **The process exiting while the binary is still absent** means failure.
     *   `&&` guarantees the shell only reaches `exec` if npm succeeded, so an
     *   exit before the binary exists is a failed install.
     */
    private fun watchInstall(target: String) {
        viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                delay(1000)
                // `agentCommand` is what the launcher itself uses to decide
                // "installed", so success and the badge cannot disagree.
                if (isLaunchable(target)) {
                    withContext(Dispatchers.Main) {
                        _installingAgentIDs.value = _installingAgentIDs.value - target
                        _installFailures.value = _installFailures.value - target
                        _installedAgents.value = _installedAgents.value + target
                    }
                    return@launch
                }
                val code = session.exitCode
                // An exit only means "this install failed" while it is still
                // this agent's session. Tapping another agent stops the pty,
                // and a stopped reader also produces an exit code — without
                // this check that interruption would be reported as the first
                // agent's failure.
                if (code != null && _spawnTarget.value == target) {
                    withContext(Dispatchers.Main) {
                        _installingAgentIDs.value = _installingAgentIDs.value - target
                        _installFailures.value = _installFailures.value +
                            (target to "install failed (exit $code) — tap to retry")
                    }
                    return@launch
                }
                if (code != null) return@launch
            }
        }
    }

    fun clearInstallState(id: String) {
        _installingAgentIDs.value = _installingAgentIDs.value - id
        _installFailures.value = _installFailures.value - id
    }

    fun spawnShellCommand(
        script: String,
        target: String = _spawnTarget.value,
        rows: Int = 24,
        cols: Int = 80
    ) {
        session.stop()
        // Whose session this *is* has to be recorded before it starts. Leaving
        // it to the caller meant an install kept the previous target, so the
        // terminal header named the wrong agent and — worse — a failure was
        // booked against that stale id, clearing the wrong card's install state
        // and leaving the agent that actually failed still marked installing.
        _spawnTarget.value = target
        val started = session.start(
            command = "/system/bin/sh",
            args = arrayOf("-c", script),
            env = spawnEnvironment(),
            cwd = SandboxHome.home(app).absolutePath
        )
        _spawned.value = started
        if (!started) {
            terminalBuffer.write("\r\nJXCode: ${session.lastError}\r\n")
            _installingAgentIDs.value = _installingAgentIDs.value - target
            _installFailures.value = _installFailures.value + (target to "could not start a shell")
        } else {
            session.resize(rows, cols)
        }
    }

    fun spawn(target: String = _spawnTarget.value, rows: Int = 24, cols: Int = 80) {
        session.stop()
        _spawnTarget.value = target

        // Three ways a spawn resolves, and the order matters:
        //
        // 1. The shell — always runnable.
        // 2. A JS entry point run by the bundled node. This is the normal case
        //    and the only one that works: the shim npm writes into the sandbox
        //    is a shebang script, and Android will not exec it from there.
        // 3. Neither — an honest shell that says so. An agent whose `bin` is a
        //    native binary lands here, and no amount of installing fixes it:
        //    those packages publish darwin/linux/win32 builds only.
        val command: String
        val args: Array<String>
        when {
            target == "shell" -> {
                command = "/system/bin/sh"
                args = arrayOf()
            }
            // A bundled agent is already in nativeLibraryDir, which is the only
            // directory Android still lets this process exec from — the same
            // reason node is launched from there rather than from the sandbox.
            target == "looper" -> {
                val looper = LooperRuntime.cliBinary(app)
                if (looper == null) {
                    command = "/system/bin/sh"
                    args = arrayOf(
                        "-c",
                        "echo 'Looper is not bundled in this APK — run android/native/build-looper.sh and rebuild.'; exec /system/bin/sh"
                    )
                } else {
                    command = looper.absolutePath
                    args = arrayOf()
                }
            }
            else -> {
                val launch = npmPackageOf(target)?.let { NodeRuntime.agentLaunch(app, it, target) }
                if (launch != null) {
                    command = launch.first
                    args = arrayOf(launch.second)
                } else {
                    command = "/system/bin/sh"
                    args = arrayOf(
                        "-c",
                        "echo '$target is not runnable here — its CLI ships a native binary with no Android build.'; exec /system/bin/sh"
                    )
                }
            }
        }

        val started = session.start(
            command = command,
            args = args,
            env = spawnEnvironment(),
            cwd = SandboxHome.home(app).absolutePath
        )
        _spawned.value = started
        if (!started) {
            terminalBuffer.write("\r\nJXCode: ${session.lastError}\r\n")
        } else {
            session.resize(rows, cols)
        }
    }

    /**
     * The environment every spawn shares.
     *
     * `fixShims` belongs here rather than in each caller: an `npm i -g` install
     * leaves a `#!/usr/bin/env node` shebang that Android cannot resolve, and
     * an agent installed moments ago is exactly the case that needs fixing.
     */
    private fun spawnEnvironment(): Array<String> {
        runCatching { NodeRuntime.fixShims(app) }
        return SandboxEnvironment.build(
            context = app,
            routerURL = router.baseURL,
            model = _selectedModel.value,
            contextLength = _selectedProvider.value?.contextLength
        )
    }

    private fun resolveOnPath(name: String): String? {
        val paths = SandboxEnvironment.path(app) + (System.getenv("PATH")?.split(':') ?: emptyList())
        for (directory in paths) {
            val candidate = File(directory, name)
            if (candidate.exists() && candidate.canExecute()) return candidate.absolutePath
        }
        return null
    }

    // MARK: - Doctor

    fun audit(): List<DoctorCheck> {
        val checks = mutableListOf<DoctorCheck>()

        checks += DoctorCheck(
            "Private \$HOME",
            SandboxHome.home(app).exists(),
            SandboxHome.home(app).absolutePath
        )

        val ptyOk = runCatching { com.jxcode.android.terminal.PtyNative.available }.getOrDefault(false)
        checks += DoctorCheck(
            "pty (libjxpty)", ptyOk,
            if (ptyOk) "forkpty available" else "native pty library not built into this APK"
        )

        checks += DoctorCheck(
            "Router", router.port != null,
            router.baseURL ?: "not listening"
        )

        checks += DoctorCheck(
            "llama.cpp (libjxllama)", LlamaBridge.isAvailable(),
            if (LlamaBridge.isAvailable()) "on-device runtime present" else "not built into this APK"
        )

        val node = NodeRuntime.nodeBinary(app)
        checks += DoctorCheck(
            "Node.js (bundled)", node != null,
            node?.absolutePath ?: "libjxnode.so missing from this APK"
        )

        val npm = resolveOnPath("npm")
        checks += DoctorCheck(
            "npm", npm != null,
            npm ?: "wrapper not written yet — npm unpacks on first boot"
        )

        checks += DoctorCheck(
            "curl (bundled)", NodeRuntime.curlBinary(app) != null,
            NodeRuntime.curlBinary(app)?.absolutePath
                ?: "libjxbin_curl.so missing from this APK"
        )

        checks += DoctorCheck(
            "Looper (bundled)", LooperRuntime.isBundled(app),
            LooperRuntime.describe(app)
        )

        checks += DoctorCheck(
            "Looper paths", LooperRuntime.home(app).isDirectory,
            if (LooperRuntime.home(app).isDirectory)
                LooperRuntime.home(app).absolutePath
            else "not created yet — Looper will refuse every subcommand"
        )

        // Termux is reported the way it actually is from inside this app,
        // which is "not reachable". Android seals one app's data directory
        // from another, so /data/data/com.termux is unreadable no matter what
        // is installed there, and Termux's RUN_COMMAND bridge stays refused
        // until the user enables external execution inside Termux itself.
        // `pm list packages` is the one probe that still works, so this
        // distinguishes "not installed" from "installed but unreachable"
        // rather than reporting a permanent false.
        val termuxInstalled = runCatching {
            app.packageManager.getPackageInfo("com.termux", 0)
            true
        }.getOrDefault(false)
        val termuxReachable = File("/data/data/com.termux/files/usr/bin").isDirectory
        checks += DoctorCheck(
            "Termux",
            termuxReachable,
            when {
                termuxReachable -> "/data/data/com.termux/files/usr/bin is readable"
                termuxInstalled -> "installed, but Android seals /data/data/com.termux " +
                    "from this app — its tools cannot be used here"
                else -> "not installed (optional — Looper and the bundled runtime are used instead)"
            }
        )

        checks += DoctorCheck(
            "Keystore-backed secrets",
            !com.jxcode.android.data.SecretStore.usingFallback,
            if (com.jxcode.android.data.SecretStore.usingFallback)
                "keystore unavailable — API keys stored unencrypted"
            else "AndroidKeyStore AES-GCM"
        )

        return checks
    }

    fun appendLog(line: String) = router.log(line)
}
