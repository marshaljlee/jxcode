package com.jxcode.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.jxcode.android.ui.theme.Palette
import com.jxcode.android.ui.theme.TileColor
import com.jxcode.android.ui.theme.Type

/**
 * The building blocks the macOS app gets from `Theme.swift`'s `Card`, `Badge`
 * and `IconTile`, so a screen here is assembled from the same parts.
 */

private val cardShape = RoundedCornerShape(12.dp)
private val badgeShape = RoundedCornerShape(percent = 50)
private val tileShape = RoundedCornerShape(8.dp)

/**
 * A rounded card with a hairline border — the workhorse surface.
 *
 * `selected` lifts it to the elevated fill and the stronger border, which is
 * how the desktop marks the chosen row without introducing a second colour.
 */
@Composable
fun AppCard(
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit
) {
    val clickable = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier
    Surface(
        modifier = modifier.then(clickable),
        shape = cardShape,
        color = if (selected) Palette.surfaceElevated else Palette.surface,
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (selected) Palette.borderStrong else Palette.border
        ),
        content = content
    )
}

/// A small uppercase heading, so sections read as sections.
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        style = Type.sectionLabel,
        modifier = modifier
    )
}

/// Pill-shaped badge — the desktop's status and count chips.
@Composable
fun Badge(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = Palette.textSecondary,
    background: Color = Palette.surfaceElevated
) {
    Text(
        text = text,
        fontSize = Type.caption,
        fontWeight = FontWeight.Medium,
        color = color,
        modifier = modifier
            .clip(badgeShape)
            .background(background)
            .padding(horizontal = 7.dp, vertical = 2.dp)
    )
}

/// The reference's amber primary button: an amber fill with dark text on it.
///
/// Deliberately not a tinted `Button` — that style paints its label white, and
/// white on amber fails contrast. Owning the label colour is why this exists.
@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    val fill = if (enabled) Palette.accentFill else Palette.surfaceElevated
    val ink = if (enabled) Palette.accentOn else Palette.textTertiary
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(7.dp))
            .background(fill)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, fontSize = Type.bodyStrong, fontWeight = FontWeight.Medium, color = ink)
    }
}

/// The quiet counterpart: a bordered control on the card surface.
@Composable
fun SecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    val ink = if (enabled) Palette.textPrimary else Palette.textTertiary
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(7.dp))
            .background(Palette.surfaceElevated)
            .border(1.dp, Palette.border, RoundedCornerShape(7.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, fontSize = Type.bodyStrong, fontWeight = FontWeight.Medium, color = ink)
    }
}

/// A rounded square with a glyph over a coloured fill — the workspace and
/// agent tiles. The ink comes from the tile, so any dot stays legible.
@Composable
fun IconTile(
    icon: ImageVector,
    tile: TileColor,
    modifier: Modifier = Modifier,
    size: Dp = 32.dp,
    description: String? = null
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(tileShape)
            .background(tile.fill),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = description,
            tint = tile.ink,
            modifier = Modifier.size(size * 0.55f)
        )
    }
}

/// A dot of a status colour — the smallest unit of the palette.
@Composable
fun StatusDot(color: Color, modifier: Modifier = Modifier, size: Dp = 7.dp) {
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(percent = 50))
            .background(color)
    )
}

/**
 * The app's title row: logo mark and product name, as the desktop's sidebar
 * header has them. `status` carries the live dots that the desktop keeps in
 * its sidebar footer, because on a phone there is no room for a second column.
 */
@Composable
fun AppHeader(
    subtitle: String,
    modifier: Modifier = Modifier,
    status: @Composable (() -> Unit)? = null
) {
    Row(
        modifier = modifier
            .background(Palette.surface)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        IconTile(
            icon = Icons.Default.Bolt,
            tile = Palette.tilePurple,
            size = 26.dp,
            description = null
        )
        Text(
            text = "JXCode",
            fontSize = Type.heading,
            fontWeight = FontWeight.SemiBold,
            color = Palette.textPrimary
        )
        Text(
            text = subtitle,
            fontSize = Type.caption,
            color = Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        if (status != null) status()
    }
}

/// A dotted status line — the desktop's router and local-model readouts.
@Composable
fun StatusLine(
    dot: Color,
    text: String,
    modifier: Modifier = Modifier,
    tint: Color = Palette.textPrimary
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        StatusDot(dot)
        Text(
            text = text,
            fontSize = Type.body,
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

/// Paths and other machine text, in mono at the desktop's detail size.
@Composable
fun MonoText(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = Palette.textTertiary,
    size: androidx.compose.ui.unit.TextUnit = Type.caption
) {
    Text(
        text = text,
        fontFamily = Type.mono,
        fontSize = size,
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
    )
}
