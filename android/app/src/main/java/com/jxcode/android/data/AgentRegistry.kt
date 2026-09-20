package com.jxcode.android.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * How an agent is pointed at the local router.
 *
 * Most agents only need the inherited `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`.
 * Two need a config file as well: Claude Code wants a token and a model name
 * present somewhere persistent, and Codex selects a provider by name from
 * `config.toml` and ignores a bare base-URL variable.
 */
@Serializable
enum class RouterBinding {
    @SerialName("environment") Environment,
    @SerialName("claudeSettings") ClaudeSettings,
    @SerialName("codexConfig") CodexConfig,
    @SerialName("none") None
}

@Serializable
data class AgentDefinition(
    val id: String,
    val name: String,
    val command: String,
    val arguments: List<String> = emptyList(),
    val installCommand: String? = null,
    val environment: Map<String, String> = emptyMap(),
    val isBuiltIn: Boolean = true,
    val webURL: String? = null,
    val routerBinding: RouterBinding = RouterBinding.Environment
)

/**
 * The agents offered in the UI.
 *
 * On Android the shell is `/system/bin/sh`, not `/bin/zsh`, and every agent is
 * a Node CLI that has to be installed into the sandbox by the runtime manager —
 * none of them ship with the app.
 */
object AgentRegistry {

    val builtIns: List<AgentDefinition> = listOf(
        AgentDefinition(
            id = "claude",
            name = "Claude Code",
            command = "claude",
            installCommand = "npm i -g @anthropic-ai/claude-code",
            routerBinding = RouterBinding.ClaudeSettings
        ),
        AgentDefinition(
            id = "codex",
            name = "Codex CLI",
            command = "codex",
            installCommand = "npm i -g @openai/codex",
            routerBinding = RouterBinding.CodexConfig
        ),
        AgentDefinition(
            id = "gemini",
            name = "Gemini CLI",
            command = "gemini",
            installCommand = "npm i -g @google/gemini-cli"
        ),
        AgentDefinition(
            id = "opencode",
            name = "opencode",
            command = "opencode",
            installCommand = "npm i -g opencode-ai"
        ),
        AgentDefinition(
            id = "omp",
            name = "oh-my-pi",
            command = "omp",
            installCommand = "npm i -g @oh-my-pi/pi-coding-agent"
        ),
        AgentDefinition(
            id = "jules",
            name = "Google Jules",
            command = "jules",
            installCommand = "npm i -g @google/jules",
            webURL = "https://jules.google.com",
            routerBinding = RouterBinding.None
        ),
        AgentDefinition(
            id = "shell",
            name = "Plain shell",
            command = "/system/bin/sh",
            routerBinding = RouterBinding.None
        )
    )

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }

    fun load(customFile: File): List<AgentDefinition> {
        val custom = try {
            if (customFile.exists()) json.decodeFromString<List<AgentDefinition>>(customFile.readText()) else emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
        val byId = builtIns.associateBy { it.id }.toMutableMap()
        custom.forEach { byId[it.id] = it }
        return byId.values.toList()
    }

    fun save(customFile: File, agents: List<AgentDefinition>) {
        runCatching {
            customFile.parentFile?.mkdirs()
            customFile.writeText(json.encodeToString(agents.filter { !it.isBuiltIn }))
        }
    }
}
