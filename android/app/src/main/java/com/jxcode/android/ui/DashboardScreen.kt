package com.jxcode.android.ui

import android.content.Context
import androidx.annotation.DrawableRes
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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jxcode.android.AppViewModel
import com.jxcode.android.R
import com.jxcode.android.SandboxHome
import com.jxcode.android.data.AgentDefinition
import com.jxcode.android.data.AgentRegistry
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.Type

/**
 * The glyph and the one-line description for each agent, ported from
 * `AgentPresentation` in the macOS app so a card here and a card there say the
 * same thing about the same agent.
 *
 * The artwork is the macOS `AgentIcons` set — `mx_brand_*` vector drawables
 * drawn from `Sources/JXCodeCore/AgentIcons.swift`, not Material Design and
 * not the generic `MXIcon` set. Each mark carries its own paint: solid fills
 * for Claude and Jules, a gradient glyph on its own white rounded square for
 * Codex, four overlaid gradients on the Gemini spark, the opencode light
 * frame around a dark inner, and the oh-my-pi gradient on its own near-black
 * rounded square.
 */
internal object AgentPresentation {

    /**
     * The brand mark for an agent, or `null` for a custom agent the icon set
     * has nothing for. Mirrors `AgentIcons.icon(for:)` on macOS.
     */
    @Composable
    fun icon(id: String): Painter? {
        val res = brandDrawable(id) ?: return null
        return painterResource(res)
    }

    /**
     * Whether the mark paints its own background across the whole view box —
     * i.e. whether to skip the surfaceElevated backdrop the desktop draws for
     * transparent marks. Mirrors `AgentIcon.fillsTile`.
     */
    fun fillsTile(id: String): Boolean = when (id) {
        "codex", "opencode", "omp" -> true
        else -> false
    }

    @DrawableRes
    private fun brandDrawable(id: String): Int? = when (id) {
        "claude" -> R.drawable.mx_brand_claude
        "codex" -> R.drawable.mx_brand_codex
        "gemini" -> R.drawable.mx_brand_gemini
        "opencode" -> R.drawable.mx_brand_opencode
        "omp" -> R.drawable.mx_brand_omp
        "jules" -> R.drawable.mx_brand_jules
        else -> null
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
    val looperReady by vm.looperReady.collectAsStateWithLifecycle()
    val preinstallProgress by vm.preinstallProgress.collectAsStateWithLifecycle()
    val preinstallDone by vm.preinstallDone.collectAsStateWithLifecycle()

    val agents = AgentRegistry.builtIns

    // The install pass runs once, on the dashboard, the first time it appears.
    // Not in the ViewModel constructor: that would put six npm downloads on the
    // critical path of the first frame, and the dashboard is what the user
    // needs to *see* that the work is happening.
    LaunchedEffect(Unit) { vm.preinstallAll() }

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
                localModel = localModel,
                looperReady = looperReady,
                preinstallProgress = preinstallProgress,
                preinstallDone = preinstallDone
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
                // A bundled agent is never installed, so it never gets an
                // install affordance — the badge would be a lie about work
                // that has already happened.
                showInstall = !agent.bundled,
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
        AppLogo(height = 44.dp)
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
    localModel: String,
    looperReady: Boolean,
    preinstallProgress: String,
    preinstallDone: Boolean
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
                icon = painterResource(R.drawable.mx_check),
                value = "$installed of $total",
                label = "agents ready",
                tint = if (installed == total) Palette.success else Palette.warning,
                modifier = Modifier.weight(1f)
            )
            DashboardStat(
                icon = painterResource(R.drawable.mx_shield),
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
                icon = painterResource(R.drawable.mx_routing),
                value = if (routing) "routing" else "off",
                label = "model route",
                tint = if (routing) Palette.accent else Palette.textTertiary,
                modifier = Modifier.weight(1f)
            )
            DashboardStat(
                icon = painterResource(R.drawable.mx_model),
                value = if (loaded) "loaded" else "off",
                label = "local model",
                tint = if (loaded) Palette.success else Palette.textTertiary,
                modifier = Modifier.weight(1f)
            )
        }

        // Looper gets a row of its own rather than displacing an existing chip:
        // it is the thing the phone is now *for*, and it ships in the APK rather
        // than being installed, so its state is known before any tap.
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            DashboardStat(
                icon = painterResource(R.drawable.mx_routing),
                value = if (looperReady) "ready" else "absent",
                label = "looper daemon",
                tint = if (looperReady) Palette.success else Palette.warning,
                modifier = Modifier.weight(1f)
            )
            DashboardStat(
                icon = painterResource(if (preinstallDone) R.drawable.mx_check else R.drawable.mx_download),
                value = if (preinstallDone) "installed" else "working",
                label = "agent install",
                tint = if (preinstallDone) Palette.success else Palette.sunlit,
                modifier = Modifier.weight(1f)
            )
        }

        // The one line that says what the app is doing right now, while it is
        // doing it. Hidden once finished — a progress line that stays at "6 of 6
        // ready" forever is noise, not information.
        if (preinstallProgress.isNotBlank() && !preinstallDone) {
            MonoText(
                text = preinstallProgress,
                color = Palette.sunlit,
                size = Type.caption,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
    }
}

/// One fact about the sandbox, as a chip.
@Composable
private fun DashboardStat(
    icon: Painter,
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
            painter = icon,
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
    showInstall: Boolean,
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
                val icon = AgentPresentation.icon(agent.id)
                if (icon != null) {
                    BrandIconTile(
                        icon = icon,
                        fillsTile = AgentPresentation.fillsTile(agent.id),
                        size = 34.dp
                    )
                } else {
                    // Custom agent with no brand mark: a generic tile, the same
                    // honest placeholder the macOS app draws for it.
                    IconTile(
                        icon = painterResource(R.drawable.mx_terminal),
                        tile = Palette.tile(forKey = agent.id),
                        size = 34.dp
                    )
                }
                Spacer(modifier = Modifier.weight(1f))
                when {
                    isInstalling -> Badge(
                        text = "installing",
                        color = Palette.sunlit,
                        background = Palette.sunlitWash
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
                    // No install to offer. Say why in one word rather than
                    // showing a button that cannot do anything.
                    !showInstall -> Badge(
                        text = "unavailable",
                        color = Palette.textSecondary
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
                val actionLabel = when {
                    isInstalled -> "Open"
                    !showInstall -> "Unavailable on Android"
                    else -> "Install and open"
                }
                val actionIcon = when {
                    isInstalled -> R.drawable.mx_arrow_right
                    !showInstall -> R.drawable.mx_shield
                    else -> R.drawable.mx_download
                }
                Text(
                    text = actionLabel,
                    fontSize = Type.body,
                    fontWeight = FontWeight.Medium,
                    color = if (isInstalled || showInstall) Palette.accent else Palette.textTertiary
                )
                Icon(
                    painter = painterResource(actionIcon),
                    contentDescription = null,
                    tint = if (isInstalled || showInstall) Palette.accent else Palette.textTertiary,
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
