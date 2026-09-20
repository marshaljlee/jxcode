package com.jxcode.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jxcode.android.AppViewModel
import com.jxcode.android.DoctorCheck
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.Type

/**
 * The doctor: what actually works on this device.
 *
 * Every line here is measured, not assumed — a terminal that cannot spawn a
 * pty and a router that is not listening look identical from the UI otherwise.
 */
@Composable
fun RuntimeScreen(viewModel: AppViewModel) {
    val log by viewModel.log.collectAsStateWithLifecycle()
    val runtime by viewModel.runtime.collectAsStateWithLifecycle()
    var checks by remember { mutableStateOf(viewModel.audit()) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.surfaceDeepest)
            .verticalScroll(rememberScrollState())
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Runtime",
                fontSize = Type.heading,
                fontWeight = FontWeight.SemiBold,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f)
            )
            SecondaryButton("Re-run", onClick = { checks = viewModel.audit() })
        }

        MonoText(runtime, color = Palette.textSecondary, size = Type.body)

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            checks.forEach { check -> CheckRow(check) }
        }

        SectionLabel("Router log")

        AppCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(10.dp)) {
                if (log.isEmpty()) {
                    Text("(empty)", fontSize = Type.body, color = Palette.textTertiary)
                } else {
                    log.takeLast(40).forEach { line ->
                        Text(
                            line,
                            fontFamily = Type.mono,
                            fontSize = Type.caption,
                            color = Palette.textSecondary
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CheckRow(check: DoctorCheck) {
    AppCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 11.dp, vertical = 9.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Badge(
                text = if (check.ok) "ready" else "check",
                color = if (check.ok) Palette.success else Palette.warning,
                background = if (check.ok) Palette.success.copy(alpha = 0.14f)
                else Palette.warning.copy(alpha = 0.14f)
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    check.name,
                    fontSize = Type.bodyStrong,
                    fontWeight = FontWeight.Medium,
                    color = Palette.textPrimary
                )
                Text(
                    check.detail,
                    fontFamily = Type.mono,
                    fontSize = Type.caption,
                    color = Palette.textTertiary
                )
            }
        }
    }
}
