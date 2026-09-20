package com.jxcode.android.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jxcode.android.AppViewModel
import com.jxcode.android.data.AgentRegistry
import com.jxcode.android.data.Provider
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.Type

/**
 * Where the app can be.
 *
 * The desktop keeps Providers and Models in *sheets* opened from the toolbar
 * and the sidebar footer, because they are configuration and the workspace is
 * the point. A phone has no room for a second column, so they become header
 * actions here — still secondary to the dashboard, not its equals in a tab
 * bar. Runtime has no desktop counterpart at all; it is this port's own
 * diagnostics, and it sits in the header for the same reason.
 */
private enum class Screen(val title: String) {
    Dashboard("JXCode"),
    Terminal("Terminal"),
    Providers("Providers"),
    Models("Models"),
    Runtime("Runtime")
}

/**
 * The shell: a title row, one pane, and nothing else.
 *
 * The dashboard is what you land on, and a terminal exists once an agent has
 * been launched — which is the order the macOS app uses, and the reason it
 * uses it is that a terminal opened before anyone chose an agent has nothing
 * in it worth reading.
 */
@Composable
fun JXCodeRoot(vm: AppViewModel = viewModel()) {
    var screen by remember { mutableStateOf(Screen.Dashboard) }
    val context: Context = LocalContext.current

    val provider: Provider? by vm.selectedProvider.collectAsStateWithLifecycle()
    val model: String? by vm.selectedModel.collectAsStateWithLifecycle()
    val spawnTarget by vm.spawnTarget.collectAsStateWithLifecycle()

    // Install state is resolved from the sandbox rather than remembered, so it
    // is re-read whenever the dashboard comes back into view — an agent
    // installed by hand in the terminal has to show up without a restart.
    LaunchedEffect(screen) {
        if (screen == Screen.Dashboard) vm.refreshInstalledAgents()
    }

    // Read once, so the header's text is decided in one place rather than by
    // three smart-cast attempts on delegated properties — which Kotlin refuses
    // to smart-cast at all.
    val routeText = when {
        provider != null && model != null -> "routing · $model"
        provider != null -> "${provider?.name} · not routing"
        else -> "no backend"
    }
    val routeDot = if (provider != null) Palette.success else Palette.textTertiary

    Column(modifier = Modifier
        .fillMaxSize()
        .background(Palette.surfaceDeepest)
        // The activity draws edge-to-edge, which is right for the terminal well
        // but wrong for the header — a status bar sitting over the title row
        // both looks wrong and (worse) eats taps meant for the header icons.
        // statusBarsPadding keeps the chrome below the system bar and the well
        // full-bleed.
        .statusBarsPadding()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Palette.surface)
                .padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (screen == Screen.Dashboard) {
                IconTile(
                    icon = Icons.Default.Bolt,
                    tile = Palette.tilePurple,
                    size = 24.dp
                )
                Text(
                    text = "JXCode",
                    fontSize = Type.heading,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.textPrimary,
                    modifier = Modifier.padding(start = 8.dp)
                )
            } else {
                IconButton(onClick = { screen = Screen.Dashboard }) {
                    Icon(
                        imageVector = Icons.Default.ArrowBack,
                        contentDescription = "Back to dashboard",
                        tint = Palette.textSecondary,
                        modifier = Modifier.size(18.dp)
                    )
                }
                Text(
                    text = if (screen == Screen.Terminal) agentName(spawnTarget) else screen.title,
                    fontSize = Type.heading,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            if (screen == Screen.Dashboard || screen == Screen.Terminal) {
                StatusLine(
                    dot = routeDot,
                    text = routeText,
                    modifier = Modifier.padding(horizontal = 6.dp)
                )
            }
            if (screen == Screen.Dashboard) {
                HeaderAction(Icons.Default.Cloud, "Providers") { screen = Screen.Providers }
                HeaderAction(Icons.Default.Memory, "Models") { screen = Screen.Models }
                HeaderAction(Icons.Default.MonitorHeart, "Runtime") { screen = Screen.Runtime }
            }
        }
        HorizontalDivider(color = Palette.border)

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when (screen) {
                Screen.Dashboard -> DashboardScreen(
                    vm = vm,
                    onLaunch = { agent ->
                        vm.launchAgent(agent)
                        screen = Screen.Terminal
                    },
                    onOpenWeb = { url -> openUrl(context, url) }
                )
                Screen.Terminal -> TerminalScreen(vm)
                Screen.Providers -> ProvidersScreen(vm)
                Screen.Models -> ModelsScreen(vm)
                Screen.Runtime -> RuntimeScreen(vm)
            }
        }
    }
}

@Composable
private fun HeaderAction(
    icon: ImageVector,
    description: String,
    onClick: () -> Unit
) {
    IconButton(onClick = onClick) {
        Icon(
            imageVector = icon,
            contentDescription = description,
            tint = Palette.textSecondary,
            modifier = Modifier.size(18.dp)
        )
    }
}

private fun agentName(target: String): String =
    AgentRegistry.builtIns.firstOrNull { it.id == target }?.name ?: "Terminal"

private fun openUrl(context: Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
