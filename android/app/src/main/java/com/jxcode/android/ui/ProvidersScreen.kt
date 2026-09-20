package com.jxcode.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jxcode.android.AppViewModel
import com.jxcode.android.data.Provider
import com.jxcode.android.data.ProviderKind
import com.jxcode.android.router.ModelRouter
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.Type

@Composable
fun ProvidersScreen(viewModel: AppViewModel) {
    val providers by viewModel.providers.collectAsStateWithLifecycle()
    val selected by viewModel.selectedProvider.collectAsStateWithLifecycle()
    val model by viewModel.selectedModel.collectAsStateWithLifecycle()
    val models by viewModel.models.collectAsStateWithLifecycle()
    val message by viewModel.fetchMessage.collectAsStateWithLifecycle()

    val scroll = rememberScrollState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.surfaceDeepest)
            .verticalScroll(scroll)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        SectionLabel("Registered backends")

        Text(
            "Agents in the terminal reach whatever is selected here, through the loopback router on port ${ModelRouter.DEFAULT_PORT}.",
            fontSize = Type.body,
            color = Palette.textSecondary
        )

        if (providers.isEmpty()) {
            Text(
                "No providers yet. Add one below — any OpenAI-compatible URL works, including a Mac on the same network.",
                fontSize = Type.body,
                color = Palette.textTertiary
            )
        }

        providers.forEach { provider ->
            ProviderCard(
                provider = provider,
                isSelected = selected?.id == provider.id,
                onSelect = { viewModel.select(provider, provider.models.firstOrNull()) },
                onFetch = { viewModel.fetchModels(provider) },
                onRemove = { viewModel.removeProvider(provider.id) }
            )
        }

        if (models.isNotEmpty()) {
            SectionLabel("Models")
            AppCard {
                Column(
                    modifier = Modifier.padding(vertical = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    models.forEach { name ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            RadioButton(
                                selected = model == name,
                                onClick = { selected?.let { viewModel.select(it, name) } },
                                colors = RadioButtonDefaults.colors(
                                    selectedColor = Palette.accent,
                                    unselectedColor = Palette.textTertiary
                                )
                            )
                            Text(
                                name,
                                fontSize = Type.bodyStrong,
                                fontFamily = Type.mono,
                                color = Palette.textPrimary,
                                modifier = Modifier.padding(start = 8.dp)
                            )
                        }
                    }
                }
            }
        }

        message?.let {
            Text(it, fontSize = Type.body, color = Palette.textSecondary)
        }

        HorizontalDivider(color = Palette.border)

        AddProviderForm(onAdd = { name, url, kind, key, context ->
            viewModel.addProvider(name, url, kind, key, context)
        })
    }
}

@Composable
private fun ProviderCard(
    provider: Provider,
    isSelected: Boolean,
    onSelect: () -> Unit,
    onFetch: () -> Unit,
    onRemove: () -> Unit
) {
    AppCard(selected = isSelected) {
        Column(
            modifier = Modifier.padding(13.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // The dot is hashed from the id, so a backend keeps the same
                // colour across launches — an identity colour, not a state.
                IconTile(
                    icon = Icons.Default.Cloud,
                    tile = Palette.tile(forKey = provider.id),
                    size = 32.dp
                )
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        provider.name,
                        fontSize = Type.title,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.textPrimary
                    )
                    MonoText(provider.normalizedBaseURL, color = Palette.textTertiary)
                }
                if (isSelected) {
                    Badge("selected", color = Palette.success, background = Palette.success.copy(alpha = 0.14f))
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Badge(
                    provider.kind.displayName,
                    color = Palette.accent,
                    background = Palette.accent.copy(alpha = 0.14f)
                )
                provider.contextLength?.let { context ->
                    Badge("${context / 1024}k ctx")
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (isSelected) {
                    SecondaryButton("Selected", onClick = onSelect, enabled = false)
                } else {
                    PrimaryButton("Select", onClick = onSelect)
                }
                SecondaryButton("Fetch models", onClick = onFetch)
                SecondaryButton("Remove", onClick = onRemove)
            }
        }
    }
}

@Composable
private fun AddProviderForm(onAdd: (String, String, ProviderKind, String, Int?) -> Unit) {
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var key by remember { mutableStateOf("") }
    var context by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf(ProviderKind.OpenAI) }
    var expanded by remember { mutableStateOf(false) }

    SectionLabel("Add a backend")

    val fields = OutlinedTextFieldDefaults.colors(
        focusedTextColor = Palette.textPrimary,
        unfocusedTextColor = Palette.textPrimary,
        focusedContainerColor = Palette.surface,
        unfocusedContainerColor = Palette.surface,
        cursorColor = Palette.accent,
        focusedBorderColor = Palette.accent,
        unfocusedBorderColor = Palette.border,
        focusedLabelColor = Palette.accent,
        unfocusedLabelColor = Palette.textTertiary
    )
    val fieldStyle = TextStyle(fontSize = Type.bodyStrong, color = Palette.textPrimary)
    val fieldShape = RoundedCornerShape(8.dp)

    OutlinedTextField(
        value = name, onValueChange = { name = it },
        label = { Text("Name", fontSize = Type.body) },
        textStyle = fieldStyle, colors = fields, shape = fieldShape,
        modifier = Modifier.fillMaxWidth(), singleLine = true
    )
    OutlinedTextField(
        value = url, onValueChange = { url = it },
        label = { Text("Base URL", fontSize = Type.body) },
        placeholder = { Text("http://192.168.1.10:8080", fontSize = Type.body, color = Palette.textTertiary) },
        textStyle = fieldStyle, colors = fields, shape = fieldShape,
        modifier = Modifier.fillMaxWidth(), singleLine = true
    )
    OutlinedTextField(
        value = key, onValueChange = { key = it },
        label = { Text("API key (optional)", fontSize = Type.body) },
        visualTransformation = PasswordVisualTransformation(),
        textStyle = fieldStyle, colors = fields, shape = fieldShape,
        modifier = Modifier.fillMaxWidth(), singleLine = true
    )

    OutlinedTextField(
        value = context, onValueChange = { context = it },
        label = { Text("Context window (optional, tokens)", fontSize = Type.body) },
        placeholder = { Text("32768", fontSize = Type.body, color = Palette.textTertiary) },
        textStyle = fieldStyle, colors = fields, shape = fieldShape,
        modifier = Modifier.fillMaxWidth(), singleLine = true
    )

    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "Kind: ${kind.displayName}",
            fontSize = Type.bodyStrong,
            color = Palette.textSecondary,
            modifier = Modifier.weight(1f)
        )
        SecondaryButton("Change", onClick = { expanded = true })
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Palette.surfaceElevated)
        ) {
            ProviderKind.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.displayName, fontSize = Type.bodyStrong, color = Palette.textPrimary) },
                    onClick = { kind = option; expanded = false }
                )
            }
        }
    }

    PrimaryButton(
        text = "Add provider",
        onClick = {
            if (name.isNotBlank() && url.isNotBlank()) {
                onAdd(name.trim(), url.trim(), kind, key, context.trim().toIntOrNull())
                name = ""; url = ""; key = ""; context = ""
            }
        },
        modifier = Modifier.fillMaxWidth()
    )
}
