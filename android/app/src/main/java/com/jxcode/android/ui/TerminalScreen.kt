package com.jxcode.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jxcode.android.AppViewModel
import com.jxcode.android.terminal.TerminalBuffer
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.TerminalPalette
import com.jxcode.android.ui.theme.Type
import kotlinx.coroutines.delay

private val chipShape = RoundedCornerShape(6.dp)

/// The agent a chip launches, and the glyph the desktop's tab bar gives it.
private fun agentIcon(name: String): ImageVector = when (name) {
    "claude" -> Icons.Default.Bolt
    "codex" -> Icons.Default.Code
    else -> Icons.Default.Terminal
}

@Composable
fun TerminalScreen(viewModel: AppViewModel) {
    val buffer = viewModel.terminalBuffer
    val spawned by viewModel.spawned.collectAsStateWithLifecycle()
    val target by viewModel.spawnTarget.collectAsStateWithLifecycle()

    // The session mutates the buffer on the main thread; sampling its version
    // is what makes this recompose.
    var version by remember { mutableStateOf(buffer.version) }
    LaunchedEffect(Unit) {
        while (true) {
            version = buffer.version
            delay(50)
        }
    }

    // 12sp mono, against the desktop's 12.5pt. Small enough to hold 80 columns
    // on a phone, which is the whole reason the terminal is a tab here.
    val textSize = 12.sp
    val measurer = rememberTextMeasurer()
    val style = remember(textSize) {
        TextStyle(fontFamily = FontFamily.Monospace, fontSize = textSize)
    }
    val density = LocalDensity.current
    val charWidth = remember(measurer, style) { measurer.measure("M", style).size.width.toFloat() }
    val lineHeight = with(density) { (textSize.toPx() * 1.3f) }
    val textSizePx = lineHeight / 1.3f

    // A single android.graphics.Paint reused for every glyph. DrawScope is
    // single-threaded on the render thread, so mutating its flags per cell
    // (bold, underline, colour) is safe and avoids the per-frame allocation
    // a fresh Paint would cost.
    val nativePaint = remember(textSizePx) {
        android.graphics.Paint().apply {
            typeface = android.graphics.Typeface.MONOSPACE
            isAntiAlias = true
            this.textSize = textSizePx
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.surfaceDeepest)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            listOf("shell", "claude", "codex").forEach { name ->
                SpawnChip(
                    name = name,
                    icon = agentIcon(name),
                    isSelected = target == name,
                    onSpawn = { viewModel.spawn(name) }
                )
            }
        }
        HorizontalDivider(color = Palette.border)

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            TerminalCanvas(
                buffer = buffer,
                version = version,
                baseStyle = style,
                charWidth = charWidth,
                lineHeight = lineHeight,
                textSizePx = textSizePx,
                nativePaint = nativePaint,
                onSize = { rows, cols -> viewModel.session.resize(rows, cols) },
                modifier = Modifier.fillMaxSize()
            )
            if (!spawned) {
                Text(
                    text = "No process yet — tap shell, claude or codex.",
                    fontSize = Type.body,
                    color = Palette.textTertiary,
                    modifier = Modifier.align(Alignment.Center)
                )
            }
        }

        HorizontalDivider(color = Palette.border)
        ModifierKeys(onSend = { viewModel.session.write(it) })
        TerminalInput(onSend = { viewModel.session.write(it) })
    }
}

/// The desktop's tab chip: a rounded selection with a glyph and a 12sp label.
@Composable
private fun SpawnChip(
    name: String,
    icon: ImageVector,
    isSelected: Boolean,
    onSpawn: () -> Unit
) {
    Row(
        modifier = Modifier
            .clip(chipShape)
            .background(if (isSelected) Palette.surfaceElevated else Color.Transparent)
            .border(
                width = 1.dp,
                color = if (isSelected) Palette.borderStrong else Palette.border,
                shape = chipShape
            )
            .clickable(onClick = onSpawn)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (isSelected) Palette.accent else Palette.textTertiary,
            modifier = Modifier.size(11.dp)
        )
        Text(
            text = name,
            fontSize = Type.bodyStrong,
            color = if (isSelected) Palette.textPrimary else Palette.textSecondary
        )
    }
}

@Composable
private fun TerminalCanvas(
    buffer: TerminalBuffer,
    version: Int,
    baseStyle: TextStyle,
    charWidth: Float,
    lineHeight: Float,
    textSizePx: Float,
    nativePaint: Paint,
    onSize: (rows: Int, cols: Int) -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            // The terminal is a well: dark in both appearances, because ANSI
            // output from the programs inside it assumes a dark surface.
            .background(TerminalPalette.background)
            .onSizeChanged { size ->
                val cols = (size.width / charWidth).toInt().coerceAtLeast(20)
                val rows = (size.height / lineHeight).toInt().coerceAtLeast(4)
                onSize(rows, cols)
            }
            .drawWithContent {
                version.hashCode() // recompose trigger: the buffer has changed

                for (row in 0 until buffer.rows) {
                    val top = row * lineHeight
                    var column = 0
                    while (column < buffer.cols) {
                        val fg = buffer.fgAt(row, column)
                        val bg = buffer.bgAt(row, column)
                        val flags = buffer.flagsAt(row, column)

                        // One draw call per run of cells sharing attributes:
                        // a row is usually a handful, not one per character.
                        val text = StringBuilder()
                        text.append(buffer.charAt(row, column))
                        var end = column + 1
                        while (end < buffer.cols) {
                            val next = buffer.charAt(row, end)
                            if (next == ' ') break
                            if (buffer.fgAt(row, end) != fg || buffer.bgAt(row, end) != bg ||
                                buffer.flagsAt(row, end) != flags
                            ) break
                            text.append(next)
                            end++
                        }

                        val x = column * charWidth
                        val reverse = flags and TerminalBuffer.FLAG_REVERSE != 0
                        val bold = flags and TerminalBuffer.FLAG_BOLD != 0

                        val background = when {
                            reverse && fg != TerminalBuffer.DEFAULT_FG -> ansiColor(fg)
                            reverse -> TerminalPalette.foreground
                            bg != TerminalBuffer.DEFAULT_BG -> ansiColor(bg)
                            else -> null
                        }
                        if (background != null) {
                            drawRect(
                                color = background,
                                topLeft = Offset(x, top),
                                size = Size((end - column) * charWidth, lineHeight)
                            )
                        }

                        val foreground = when {
                            reverse -> TerminalPalette.background
                            fg == TerminalBuffer.DEFAULT_FG -> TerminalPalette.foreground
                            else -> ansiColor(if (bold && fg < 8) fg + 8 else fg)
                        }

                        // Native canvas drawing rather than Compose's drawText.
                        //
                        // The TextPainter path goes through Constraints(min, max)
                        // and the overload's default maxWidth occasionally resolved
                        // to a negative value, crashing the whole activity with
                        // `maxWidth(-3) must be >= minWidth(0)` on the very first
                        // draw. A terminal is a grid of fixed-width glyphs on a
                        // fixed background — there is no layout to compute — so
                        // drawing directly onto the native canvas is both correct
                        // and immune to whatever defaults the Compose overload
                        // happens to have in this BOM release.
                        drawIntoCanvas { canvas ->
                            nativePaint.color = foreground.toArgb()
                            nativePaint.isFakeBoldText = bold
                            nativePaint.isUnderlineText =
                                (flags and TerminalBuffer.FLAG_UNDERLINE) != 0
                            // drawText takes a baseline; the row's top is the
                            // glyph top, so baseline ≈ top + ascent. With
                            // Typeface.MONOSPACE the ascent is close to the
                            // font size, so the row reads as aligned to the
                            // cell box.
                            val baseline = top + textSizePx
                            canvas.nativeCanvas.drawText(text.toString(), x, baseline, nativePaint)
                        }
                        column = end
                    }
                }

                if (buffer.cursorVisible) {
                    drawRect(
                        color = TerminalPalette.cursor,
                        topLeft = Offset(buffer.cursorCol * charWidth, buffer.cursorRow * lineHeight),
                        size = Size(charWidth, lineHeight)
                    )
                }
            }
    )
}

/**
 * The keys a phone keyboard has no room for.
 *
 * Height 32dp and 11sp rather than the Material defaults: this row sits under
 * the terminal and beside the software keyboard, so every dip it takes is a
 * dip the terminal does not get.
 */
@Composable
private fun ModifierKeys(onSend: (String) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        listOf(
            "ESC" to "\u001B",
            "TAB" to "\t",
            "^C" to "\u0003",
            "^D" to "\u0004",
            "\u2191" to "\u001B[A",
            "\u2193" to "\u001B[B",
            "\u2190" to "\u001B[D",
            "\u2192" to "\u001B[C"
        ).forEach { (label, sequence) ->
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(7.dp))
                    .background(Palette.surfaceElevated)
                    .clickable { onSend(sequence) }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(label, fontSize = Type.body, color = Palette.textSecondary)
            }
        }
    }
}

/**
 * Software-keyboard capture.
 *
 * A terminal has no text field, but an IME only sends characters to something
 * with an InputConnection, so a one-dip field sits behind the canvas and
 * forwards the difference between successive values. Without it the keyboard
 * opens and types nothing at all.
 */
@Composable
private fun TerminalInput(onSend: (String) -> Unit) {
    var value by remember { mutableStateOf(TextFieldValue("")) }

    BasicTextField(
        value = value,
        onValueChange = { next ->
            val previous = value.text
            val current = next.text
            when {
                current.length > previous.length && current.startsWith(previous) ->
                    onSend(current.substring(previous.length))
                previous.length > current.length && previous.startsWith(current) ->
                    onSend("\u007F".repeat(previous.length - current.length))
                current != previous -> onSend(current)
            }
            value = if (current.length > 32) TextFieldValue("") else next
        },
        modifier = Modifier.size(1.dp),
        textStyle = TextStyle(fontSize = 1.sp, color = Color.Transparent),
        decorationBox = { inner -> Box(Modifier.size(1.dp)) { inner() } }
    )
}

/** Maps an ANSI index onto the app's palette. */
private fun ansiColor(index: Int): Color {
    if (index in 16..231) {
        val n = index - 16
        val levels = intArrayOf(0, 95, 135, 175, 215, 255)
        val r = levels[n / 36]
        val g = levels[(n % 36) / 6]
        val b = levels[n % 6]
        return Color(r, g, b)
    }
    if (index in 232..255) {
        val value = 8 + (index - 232) * 10
        return Color(value, value, value)
    }
    return when (index) {
        0 -> TerminalPalette.black
        1 -> TerminalPalette.red
        2 -> TerminalPalette.green
        3 -> TerminalPalette.yellow
        4 -> TerminalPalette.blue
        5 -> TerminalPalette.magenta
        6 -> TerminalPalette.cyan
        7 -> TerminalPalette.white
        8 -> TerminalPalette.brightBlack
        9 -> TerminalPalette.brightRed
        10 -> TerminalPalette.brightGreen
        11 -> TerminalPalette.brightYellow
        12 -> TerminalPalette.brightBlue
        13 -> TerminalPalette.brightMagenta
        14 -> TerminalPalette.brightCyan
        15 -> TerminalPalette.brightWhite
        else -> TerminalPalette.foreground
    }
}
