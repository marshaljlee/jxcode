package com.jxcode.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * An identity colour: the fill, and the ink that stays legible on it.
 *
 * The ramp is hashed, so any given key can land on any dot and every dot has
 * to carry a readable glyph. White does not: it is 1.81:1 on `amber`, 2.61:1
 * on `orange` and 2.90:1 on `green`, all under the 3:1 floor for a non-text
 * graphic, while the other four are 3.34:1 or better and want white. The inks
 * below are that decision, precomputed — see `Palette.swift` in JXCodeCore for
 * the rule they come from.
 */
@Immutable
data class TileColor(val fill: Color, val ink: Color)

/**
 * The visual language, ported from `Theme.swift` / `Palette.swift` in the
 * macOS app so the two read as one design.
 *
 * What carries over, and why:
 *
 * - **The base is warm, not blue-grey.** Every surface carries a little red
 *   and yellow; nothing here is a neutral grey. `#141319` is the page,
 *   `#191919` a card, `#242427` the raised fill.
 * - **One accent, amber `#FEB43B`.** It is used as a *fill* with dark ink on
 *   top, never as coloured text on a light surface. `accent` (readable amber)
 *   and `accentFill` (the button colour) are separate for that reason.
 * - **Borders are low-alpha white**, so a single constant reads as a hint on
 *   every surface instead of as a stroke tuned to one.
 *
 * The terminal keeps its own ANSI ramp (`TerminalPalette`): a terminal is a
 * well, and an ANSI palette is a functional contract with the programs that
 * emit it, not a brand surface.
 */
object Palette {

    // MARK: - Surfaces

    /// The page behind everything. Deepest of the three.
    val surfaceDeepest = Color(0xFF141319)
    /// Cards and panels — the workhorse surface.
    val surface = Color(0xFF191919)
    /// The selected or hovered fill: a raised panel.
    val surfaceElevated = Color(0xFF242427)
    /// A well — code, terminal, anything inset rather than raised.
    val surfaceSunken = Color(0xFF0F0E13)

    // MARK: - Lines

    /// White at 8%, the desktop's dark-mode stop.
    val border = Color(0x14FFFFFF)
    /// White at 15% — the hover/selected edge.
    val borderStrong = Color(0x26FFFFFF)

    // MARK: - Text

    val textPrimary = Color(0xFFEDEBE8)
    val textSecondary = Color(0xFF9C9C9C)
    /// The inactive tier, held to the *graphic* floor rather than the text
    /// floor: this is what unselected icons and idle dots are drawn in.
    val textTertiary = Color(0xFF717176)

    // MARK: - Accent

    val accent = Color(0xFFFEB43B)
    val accentFill = Color(0xFFFEB43B)
    val accentHover = Color(0xFFFFC55E)
    /// Text and glyphs drawn *on* `accentFill`. Amber with white text fails
    /// contrast, which is the whole reason this exists.
    val accentOn = Color(0xFF1F1E1C)

    // MARK: - Status

    val success = Color(0xFF4BAC65)
    val warning = Color(0xFFF5B549)
    val danger = Color(0xFFF45F59)
    val info = Color(0xFF40C8E0)

    // MARK: - Identity dots

    val tileAmber = TileColor(Color(0xFFF5B549), Color(0xFF1F1E1C))
    val tileBlue = TileColor(Color(0xFF538EDE), Color(0xFFFFFFFF))
    val tileGreen = TileColor(Color(0xFF44AB62), Color(0xFF1F1E1C))
    val tileTeal = TileColor(Color(0xFF41969D), Color(0xFFFFFFFF))
    val tilePurple = TileColor(Color(0xFF845FC9), Color(0xFFFFFFFF))
    val tilePink = TileColor(Color(0xFFAA5BD0), Color(0xFFFFFFFF))
    val tileOrange = TileColor(Color(0xFFF97B64), Color(0xFF1F1E1C))

    /**
     * Deterministic accent for a key, so the same workspace always gets the
     * same dot and the eye learns where it lives.
     *
     * FNV-1a rather than `String.hashCode` — the values have to be stable
     * across processes, which `hashCode` is not (and a relaunch reshuffling
     * every dot is the bug this prevents).
     */
    fun tile(forKey: String): TileColor {
        return when (floorMod(stableHash(forKey), 6)) {
            0 -> tilePurple
            1 -> tileOrange
            2 -> tileTeal
            3 -> tilePink
            4 -> tileGreen
            else -> tileAmber
        }
    }

    /// FNV-1a, 64-bit.
    private fun stableHash(value: String): Long {
        var hash = -3750763034362895579L // 0xcbf29ce484222325
        for (byte in value.toByteArray()) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= 0x100000001B3L
        }
        return hash
    }

    private fun floorMod(value: Long, modulus: Int): Int {
        val remainder = (value % modulus).toInt()
        return if (remainder < 0) remainder + modulus else remainder
    }
}

/**
 * The terminal's own colours.
 *
 * `background` and `foreground` are a near-neighbour of `Palette.surfaceSunken`
 * — a terminal is a well, so it is dark in both appearances. The ANSI ramp is
 * functional: it is what the programs running inside the pty emit, so it is
 * not re-sampled to match the chrome.
 */
object TerminalPalette {
    val background = Color(0xFF131418)
    val foreground = Color(0xFFF2F5F7)
    val cursor = Color(0xFFFEB43B)

    val black = Color(0xFF1B2029)
    val red = Color(0xFFE06C75)
    val green = Color(0xFF98C379)
    val yellow = Color(0xFFE5C07B)
    val blue = Color(0xFF61AFEF)
    val magenta = Color(0xFFC678DD)
    val cyan = Color(0xFF56B6C2)
    val white = Color(0xFFD5DAE2)

    val brightBlack = Color(0xFF5C6370)
    val brightRed = Color(0xFFFF7B86)
    val brightGreen = Color(0xFFB5E08C)
    val brightYellow = Color(0xFFF2D194)
    val brightBlue = Color(0xFF7FC4FF)
    val brightMagenta = Color(0xFFDDA0EE)
    val brightCyan = Color(0xFF6FD6E2)
    val brightWhite = Color(0xFFFFFFFF)
}

/**
 * The type scale: small, and deliberately so.
 *
 * These are the sizes the macOS app uses (10pt tertiary, 11pt secondary, 13pt
 * card titles, 21pt the dashboard hero) at sp rather than pt. The Material
 * roles are pinned to them below, because a default `bodyLarge` of 16sp is
 * what makes a Compose screen read as a different app from the SwiftUI one.
 */
object Type {
    val micro = 9.sp
    /// Tertiary text, badges, uppercase section headings.
    val caption = 10.sp
    /// Body copy and mono detail lines.
    val body = 11.sp
    /// Buttons and secondary body.
    val bodyStrong = 12.sp
    /// Card and row titles.
    val title = 13.sp
    /// Product name and screen headings.
    val heading = 14.sp
    /// Sheet titles.
    val sheet = 15.sp
    /// The one large number on a screen.
    val hero = 21.sp

    val mono = FontFamily.Monospace

    /// Uppercase section heading: small, tracked out, tertiary.
    val sectionLabel = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = caption,
        letterSpacing = 0.7.sp,
        color = Palette.textTertiary
    )

    val code = TextStyle(fontFamily = mono, fontSize = body, color = Palette.textSecondary)
}

private val JXCodeTypography = Typography(
    displayLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 32.sp),
    displayMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 26.sp),
    displaySmall = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    headlineLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = Type.hero),
    headlineMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 18.sp),
    headlineSmall = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 16.sp),
    titleLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = Type.sheet),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = Type.heading),
    titleSmall = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = Type.title),
    bodyLarge = TextStyle(fontWeight = FontWeight.Normal, fontSize = Type.title),
    bodyMedium = TextStyle(fontWeight = FontWeight.Normal, fontSize = Type.bodyStrong),
    bodySmall = TextStyle(fontWeight = FontWeight.Normal, fontSize = Type.body),
    labelLarge = TextStyle(fontWeight = FontWeight.Medium, fontSize = Type.bodyStrong),
    labelMedium = TextStyle(fontWeight = FontWeight.Medium, fontSize = Type.body),
    labelSmall = TextStyle(fontWeight = FontWeight.Medium, fontSize = Type.caption)
)

/**
 * The colour scheme is the desktop palette, so a Material component that is
 * not explicitly styled still lands on the right surface — an unstyled
 * `Card` or `DropdownMenu` is the usual way a screen drifts.
 */
private val JXCodeColors = darkColorScheme(
    primary = Palette.accent,
    onPrimary = Palette.accentOn,
    primaryContainer = Palette.accentFill,
    onPrimaryContainer = Palette.accentOn,
    secondary = Palette.tileBlue.fill,
    onSecondary = Palette.tileBlue.ink,
    background = Palette.surfaceDeepest,
    onBackground = Palette.textPrimary,
    surface = Palette.surface,
    onSurface = Palette.textPrimary,
    surfaceVariant = Palette.surfaceElevated,
    onSurfaceVariant = Palette.textSecondary,
    surfaceContainer = Palette.surface,
    surfaceContainerHighest = Palette.surfaceElevated,
    outline = Palette.border,
    outlineVariant = Palette.borderStrong,
    error = Palette.danger,
    onError = Palette.accentOn
)

@Composable
fun JXCodeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = JXCodeColors,
        typography = JXCodeTypography,
        content = content
    )
}
