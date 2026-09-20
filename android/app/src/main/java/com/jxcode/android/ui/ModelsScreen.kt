package com.jxcode.android.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jxcode.android.AppViewModel
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.Type

/**
 * Local GGUF, running in-process through llama.cpp.
 *
 * Context sizes are kept modest: a phone has far less usable RAM than the
 * number on the box suggests, and the KV cache is what actually runs out.
 */
@Composable
fun ModelsScreen(viewModel: AppViewModel) {
    val models by viewModel.localModels.collectAsStateWithLifecycle()
    val state by viewModel.llamaState.collectAsStateWithLifecycle()

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            // The picker hands back a content URI; llama.cpp needs a real path.
            // Copying into the app's own storage is the reliable translation,
            // and it also keeps the model inside the sandbox.
            viewModel.importModel(uri)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.surfaceDeepest)
            .verticalScroll(rememberScrollState())
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        SectionLabel("On-device GGUF")

        StatusLine(dot = runtimeDot(state), text = state)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PrimaryButton("Scan", onClick = { viewModel.refreshLocalModels() })
            SecondaryButton("Pick .gguf", onClick = {
                picker.launch(arrayOf("application/octet-stream", "*/*"))
            })
            SecondaryButton("Unload", onClick = { viewModel.unloadLocalModel() })
        }

        Text(
            "Scans Download, Models and this app's storage. A 2–4 GB Q4 model is the practical ceiling on a phone.",
            fontSize = Type.body,
            color = Palette.textTertiary
        )

        if (models.isEmpty()) {
            HorizontalDivider(color = Palette.border)
            Text(
                "No .gguf files found. Use Pick .gguf to copy one in, or drop one into Download.",
                fontSize = Type.body,
                color = Palette.textTertiary
            )
        }

        models.forEach { model ->
            AppCard {
                Column(
                    modifier = Modifier.padding(13.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconTile(
                            icon = Icons.Default.Memory,
                            tile = Palette.tile(forKey = model.file.name),
                            size = 32.dp
                        )
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                model.file.name,
                                fontSize = Type.title,
                                fontWeight = FontWeight.SemiBold,
                                color = Palette.textPrimary
                            )
                            MonoText(
                                "${formatBytes(model.sizeBytes)} · ${model.file.parent}",
                                color = Palette.textTertiary
                            )
                        }
                    }
                    PrimaryButton("Load", onClick = { viewModel.loadLocalModel(model) })
                }
            }
        }
    }
}

/// What the runtime line is saying, as a dot — the state is a string from the
/// bridge, and the card should read at a glance rather than be parsed.
private fun runtimeDot(state: String): androidx.compose.ui.graphics.Color = when {
    state.startsWith("loaded") -> Palette.success
    state.startsWith("loading") -> Palette.warning
    state.startsWith("failed") || state.startsWith("import failed") -> Palette.danger
    else -> Palette.textTertiary
}

fun formatBytes(bytes: Long): String {
    if (bytes <= 0) return "0 B"
    val units = arrayOf("B", "KB", "MB", "GB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1000.0 && unit < units.lastIndex) {
        value /= 1000.0
        unit++
    }
    return "%.1f %s".format(value, units[unit])
}
