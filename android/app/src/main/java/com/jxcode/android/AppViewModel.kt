package com.jxcode.android

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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

data class LocalModel(val file: File, val sizeBytes: Long)

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

    fun refreshLocalModels() {
        viewModelScope.launch(Dispatchers.IO) {
            val roots = listOfNotNull(
                File("/storage/emulated/0/Download"),
                File("/storage/emulated/0/Models"),
                File(app.getExternalFilesDir(null)?.absolutePath ?: ""),
                File(SandboxHome.root(app), "models")
            ).filter { it.exists() }
            val found = roots.flatMap { root ->
                (root.listFiles { file -> file.extension.equals("gguf", ignoreCase = true) } ?: emptyArray())
                    .map { LocalModel(it, it.length()) }
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
            _llamaState.value = "loading ${model.file.name}…"
            val ok = LlamaBridge.load(model.file.absolutePath)
            _llamaState.value = if (ok) "loaded: ${model.file.name}" else "failed: ${LlamaBridge.lastError}"

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
                .filter { agentCommand(it.id) != null }
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
    fun launchAgent(agent: com.jxcode.android.data.AgentDefinition) {
        if (agentCommand(agent.id) != null) {
            spawn(agent.id)
            return
        }
        val install = agent.installCommand
        if (install == null) {
            spawn(agent.id)
            return
        }
        _installingAgentIDs.value = _installingAgentIDs.value + agent.id
        _installFailures.value = _installFailures.value - agent.id
        spawnShellCommand("$install && exec ${agent.command}")
    }

    fun clearInstallState(id: String) {
        _installingAgentIDs.value = _installingAgentIDs.value - id
        _installFailures.value = _installFailures.value - id
    }

    fun spawnShellCommand(script: String, rows: Int = 24, cols: Int = 80) {
        session.stop()
        val started = session.start(
            command = "/system/bin/sh",
            args = arrayOf("-c", script),
            env = spawnEnvironment(),
            cwd = SandboxHome.home(app).absolutePath
        )
        _spawned.value = started
        if (!started) {
            terminalBuffer.write("\r\nJXCode: ${session.lastError}\r\n")
            val target = _spawnTarget.value
            _installingAgentIDs.value = _installingAgentIDs.value - target
            _installFailures.value = _installFailures.value + (target to "could not start a shell")
        } else {
            session.resize(rows, cols)
        }
    }

    fun spawn(target: String = _spawnTarget.value, rows: Int = 24, cols: Int = 80) {
        val command = agentCommand(target) ?: "/system/bin/sh"
        val args = when {
            target == "shell" -> arrayOf()
            command.endsWith("/sh") -> arrayOf(
                "-c",
                "echo 'agent not installed — open it from the dashboard to install'; exec /system/bin/sh"
            )
            else -> arrayOf()
        }

        session.stop()
        _spawnTarget.value = target
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
            "Termux", File("/data/data/com.termux/files/usr/bin/node").exists(),
            if (File("/data/data/com.termux/files/usr/bin/node").exists())
                "/data/data/com.termux/files/usr/bin/node"
            else "not installed (optional — the bundled runtime is used instead)"
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
