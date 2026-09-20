package com.jxcode.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jxcode.android.AppViewModel
import com.jxcode.android.SandboxHome
import com.jxcode.android.data.AgentDefinition
import com.jxcode.android.data.AgentRegistry
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.Type

/**
 * The glyph and the one-line description for each agent, ported from
 * `AgentPresentation` in the macOS app so a card here and a card there say the
 * same thing about the same agent.
 */
internal object AgentPresentation {

    fun icon(id: String): ImageVector = when (id) {
        "claude" -> Icons.Default.AutoAwesome
        "codex" -> Icons.Default.Code
        "gemini" -> Icons.Default.Star
        "opencode" -> Icons.Default.Terminal
        "omp" -> Icons.Default.Bolt
        "jules" -> Icons.Default.Cloud
        else -> Icons.Default.Terminal
    }

    /**
     * What *kind* of agent this is, before anyone clicks.
     *
     * "oh-my-pi" is described as the coding agent it is, not as Oh My Posh —
     * that is a shell prompt theme engine and a different project entirely.
     * The one thing this line must not do is describe the agent as something
     * it is not.
     */
    fun tagline(id: String): String = when (id) {
        "claude" -> "Anthropic's coding agent"
        "codex" -> "OpenAI's coding agent"
        "gemini" -> "Google's CLI agent"
        "opencode" -> "Open-source terminal coding agent"
        "omp" -> "Coding agent with the IDE wired in"
        "jules" -> "Google's async coding agent"
        "shell" -> "Plain shell inside the sandbox"
        else -> "Custom agent"
    }
}

/**
 * What the app shows before any agent is running: the launcher.
 *
 * This is the front door, so it is laid out as a dashboard rather than as a
 * list — a hero that says where you are, a block of facts about the sandbox,
 * then every agent as a card. The macOS app does exactly this, and the reason
 * survives the move to a phone: a bare list answers "which agent" without
 * first answering "what am I looking at".
 */
@Composable
fun DashboardScreen(
    vm: AppViewModel,
    onLaunch: (AgentDefinition) -> Unit,
    onOpenWeb: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val context: Context = LocalContext.current
    val home = remember(context) { SandboxHome.home(context).absolutePath }

    val installed by vm.installedAgents.collectAsStateWithLifecycle()
    val installing by vm.installingAgentIDs.collectAsStateWithLifecycle()
    val failures by vm.installFailures.collectAsStateWithLifecycle()
    val sandboxOk by vm.sandboxOk.collectAsStateWithLifecycle()
    val provider by vm.selectedProvider.collectAsStateWithLifecycle()
    val localModel by vm.llamaState.collectAsStateWithLifecycle()

    val agents = AgentRegistry.builtIns

    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 164.dp),
        modifier = modifier
            .fillMaxSize()
            .background(Palette.surfaceDeepest),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            DashboardHero(home = home)
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            DashboardFacts(
                installed = installed.size,
                total = agents.size,
                sandboxOk = sandboxOk,
                routing = provider != null,
                localModel = localModel
            )
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            SectionLabel(
                text = "Agents",
                modifier = Modifier.padding(top = 8.dp, bottom = 2.dp)
            )
        }

        items(agents, key = { it.id }) { agent ->
            AgentCard(
                agent = agent,
                isInstalled = installed.contains(agent.id),
                isInstalling = installing.contains(agent.id),
                failure = failures[agent.id],
                onLaunch = { onLaunch(agent) },
                onOpenWeb = { agent.webURL?.let(onOpenWeb) }
            )
        }
    }
}

/// The opening block: where you are, and what to do.
@Composable
private fun DashboardHero(home: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(13.dp),
        verticalAlignment = Alignment.Top
    ) {
        IconTile(
            icon = Icons.Default.Bolt,
            tile = Palette.tilePurple,
            size = 44.dp
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "JXCode",
                fontSize = Type.hero,
                fontWeight = FontWeight.SemiBold,
                color = Palette.textPrimary
            )
            MonoText(text = home, modifier = Modifier.padding(top = 2.dp))
            Text(
                text = "Start an agent below. Each one runs inside the sandbox, "
                    + "isolated from the rest of your device.",
                fontSize = Type.body,
                color = Palette.textSecondary,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
    }
}

/**
 * The sandbox in four chips.
 *
 * Read-only on purpose. Each answers a question that would otherwise mean
 * opening another screen: how many agents are ready, whether the isolation is
 * intact, whether anything is routing, and whether a local model is loaded.
 */
@Composable
private fun DashboardFacts(
    installed: Int,
    total: Int,
    sandboxOk: Boolean,
    routing: Boolean,
    localModel: String
) {
    val loaded = localModel.startsWith("loaded")
    // Two by two rather than the desktop's single row: four chips across a
    // phone would leave each one too narrow for its own label.
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            DashboardStat(
                icon = Icons.Default.Check,
                value = "$installed of $total",
                label = "agents ready",
                tint = if (installed == total) Palette.success else Palette.warning,
                modifier = Modifier.weight(1f)
            )
            DashboardStat(
                icon = Icons.Default.Shield,
                value = if (sandboxOk) "isolated" else "check",
                label = "sandbox",
                tint = if (sandboxOk) Palette.success else Palette.warning,
                modifier = Modifier.weight(1f)
            )
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            DashboardStat(
                icon = Icons.Default.Cloud,
                value = if (routing) "routing" else "off",
                label = "model route",
                tint = if (routing) Palette.accent else Palette.textTertiary,
                modifier = Modifier.weight(1f)
            )
            DashboardStat(
                icon = Icons.Default.Memory,
                value = if (loaded) "loaded" else "off",
                label = "local model",
                tint = if (loaded) Palette.success else Palette.textTertiary,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

/// One fact about the sandbox, as a chip.
@Composable
private fun DashboardStat(
    icon: ImageVector,
    value: String,
    label: String,
    tint: Color,
    modifier: Modifier = Modifier
) {
    val shape = RoundedCornerShape(9.dp)
    Row(
        modifier = modifier
            .clip(shape)
            .background(Palette.surface)
            .border(1.dp, Palette.border, shape)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(14.dp)
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = value,
                fontSize = Type.body,
                fontWeight = FontWeight.SemiBold,
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = label,
                fontSize = Type.caption,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/**
 * One agent in the launcher grid.
 *
 * A whole card is a single target: tapping it installs the agent if it is
 * missing and then opens it, which is the same contract the macOS card has.
 * The difference from a bare row is that the state is legible *before* the tap
 * — the badge says `ready`, `install`, `installing` or `retry` rather than
 * leaving the user to discover it by trying.
 */
@Composable
private fun AgentCard(
    agent: AgentDefinition,
    isInstalled: Boolean,
    isInstalling: Boolean,
    failure: String?,
    onLaunch: () -> Unit,
    onOpenWeb: () -> Unit
) {
    val subtitle = when {
        failure != null -> "Install failed — tap to try again"
        isInstalling -> "Installing…"
        else -> AgentPresentation.tagline(agent.id)
    }

    AppCard(
        onClick = onLaunch,
        modifier = Modifier.heightIn(min = 132.dp)
    ) {
        Column(
            modifier = Modifier.padding(13.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp)
        ) {
            Row(verticalAlignment = Alignment.Top) {
                IconTile(
                    icon = AgentPresentation.icon(agent.id),
                    tile = Palette.tile(forKey = agent.id),
                    size = 34.dp
                )
                Spacer(modifier = Modifier.weight(1f))
                when {
                    isInstalling -> Badge(
                        text = "installing",
                        color = Palette.accent,
                        background = Palette.accent.copy(alpha = 0.14f)
                    )
                    failure != null -> Badge(
                        text = "retry",
                        color = Palette.warning,
                        background = Palette.warning.copy(alpha = 0.14f)
                    )
                    isInstalled -> Badge(
                        text = "ready",
                        color = Palette.success,
                        background = Palette.success.copy(alpha = 0.14f)
                    )
                    else -> Badge(text = "install", color = Palette.textSecondary)
                }
            }

            Column {
                Text(
                    text = agent.name,
                    fontSize = Type.title,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = subtitle,
                    fontSize = Type.body,
                    color = if (failure == null) Palette.textSecondary else Palette.warning,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = if (isInstalled) "Open" else "Install and open",
                    fontSize = Type.body,
                    fontWeight = FontWeight.Medium,
                    color = Palette.accent
                )
                Icon(
                    imageVector = if (isInstalled) Icons.Default.ArrowForward
                    else Icons.Default.Download,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(11.dp)
                )
                Spacer(modifier = Modifier.weight(1f))
                // Only the async agents have a second surface. Jules dispatches
                // to a cloud VM, so its web dashboard is where the work is
                // watched rather than the terminal.
                if (agent.webURL != null) {
                    Text(
                        text = "Dashboard",
                        fontSize = Type.caption,
                        fontWeight = FontWeight.Medium,
                        color = Palette.textSecondary,
                        modifier = Modifier.clickable(onClick = onOpenWeb)
                    )
                }
            }
        }
    }
}
