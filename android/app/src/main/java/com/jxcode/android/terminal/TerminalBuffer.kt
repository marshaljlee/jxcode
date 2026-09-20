package com.jxcode.android.terminal

import kotlin.math.max
import kotlin.math.min

/**
 * A VT100/ANSI screen buffer with an inline parser.
 *
 * Written rather than borrowed because the renderer and the parser have to
 * agree on what a cell is: agent TUIs (Claude Code especially) redraw by
 * moving the cursor and erasing lines, so an append-only "scrollback of
 * lines" renderer shows them as garbage. Cursor addressing, erase-in-line and
 * scroll regions are therefore first-class here.
 *
 * Not a complete terminal: no sixel, no DCS, no mouse reporting. Everything a
 * TUI actually emits is handled, and anything unrecognised is skipped rather
 * than rendered as noise.
 */
class TerminalBuffer(cols: Int, rows: Int) {

    companion object {
        const val DEFAULT_FG = -1
        const val DEFAULT_BG = -1

        const val FLAG_BOLD = 1 shl 0
        const val FLAG_ITALIC = 1 shl 1
        const val FLAG_UNDERLINE = 1 shl 2
        const val FLAG_REVERSE = 1 shl 3
        const val FLAG_DIM = 1 shl 4

        private const val STATE_GROUND = 0
        private const val STATE_ESC = 1
        private const val STATE_CSI = 2
        private const val STATE_OSC = 3
        private const val STATE_CHARSET = 4
    }

    var cols: Int = max(1, cols)
        private set
    var rows: Int = max(1, rows)
        private set

    private var chars = CharArray(this.cols * this.rows) { ' ' }
    private var fgColors = IntArray(this.cols * this.rows) { DEFAULT_FG }
    private var bgColors = IntArray(this.cols * this.rows) { DEFAULT_BG }
    private var flags = IntArray(this.cols * this.rows)

    var cursorRow = 0
        private set
    var cursorCol = 0
        private set

    var cursorVisible = true
        private set

    private var scrollTop = 0
    private var scrollBottom = this.rows - 1

    private var savedRow = 0
    private var savedCol = 0

    private var currentFg = DEFAULT_FG
    private var currentBg = DEFAULT_BG
    private var currentFlags = 0

    /** Alternate screen buffer: TUIs switch to it so the shell underneath survives. */
    private var altChars: CharArray? = null
    private var altFg: IntArray? = null
    private var altBg: IntArray? = null
    private var altFlags: IntArray? = null
    private var inAltScreen = false

    /** Bumped on every visible change; the renderer observes it. */
    var version: Int = 0
        private set

    /** Scrollback above the viewport, capped so a long session cannot OOM. */
    private val scrollback = ArrayDeque<CharArray>()
    private val scrollbackLimit = 5000

    private var state = STATE_GROUND
    private val params = StringBuilder()
    private val oscBuffer = StringBuilder()
    private var intermediate = ' '
    private var privateMode = false

    // MARK: - Reading

    fun charAt(row: Int, col: Int): Char {
        val index = index(row, col) ?: return ' '
        return chars[index]
    }

    fun fgAt(row: Int, col: Int): Int {
        val index = index(row, col) ?: return DEFAULT_FG
        return fgColors[index]
    }

    fun bgAt(row: Int, col: Int): Int {
        val index = index(row, col) ?: return DEFAULT_BG
        return bgColors[index]
    }

    fun flagsAt(row: Int, col: Int): Int {
        val index = index(row, col) ?: return 0
        return flags[index]
    }

    private fun index(row: Int, col: Int): Int? {
        if (row < 0 || row >= rows || col < 0 || col >= cols) return null
        return row * cols + col
    }

    // MARK: - Writing

    fun write(text: String) {
        for (ch in text) feed(ch)
        version++
    }

    private fun feed(ch: Char) {
        when (state) {
            STATE_GROUND -> when (ch) {
                '\u001B' -> { state = STATE_ESC; params.clear(); privateMode = false; intermediate = ' ' }
                '\r' -> cursorCol = 0
                '\n' -> newLine()
                '\b' -> if (cursorCol > 0) cursorCol--
                '\t' -> cursorCol = min(cols - 1, (cursorCol / 8 + 1) * 8)
                '\u0007' -> Unit // bell
                else -> put(ch)
            }

            STATE_ESC -> when (ch) {
                '[' -> { state = STATE_CSI; params.clear(); privateMode = false; intermediate = ' ' }
                ']' -> { state = STATE_OSC; oscBuffer.clear() }
                '(' , ')' -> { state = STATE_CHARSET }
                '7' -> { savedRow = cursorRow; savedCol = cursorCol; state = STATE_GROUND }
                '8' -> { cursorRow = savedRow; cursorCol = savedCol; state = STATE_GROUND }
                'D' -> { newLine(); state = STATE_GROUND }
                'M' -> { reverseIndex(); state = STATE_GROUND }
                'c' -> { reset(); state = STATE_GROUND }
                else -> state = STATE_GROUND
            }

            STATE_CHARSET -> state = STATE_GROUND // G0/G1 selection: ignored

            STATE_OSC -> when (ch) {
                '\u0007' -> state = STATE_GROUND
                '\u001B' -> state = STATE_ESC
                else -> {
                    // Terminated by BEL or by ESC \; only the title matters here
                    // and it is not rendered, so the payload is simply drained.
                    if (oscBuffer.length < 512) oscBuffer.append(ch)
                }
            }

            STATE_CSI -> when (ch) {
                in '0'..'9' -> params.append(ch)
                ';' -> params.append(';')
                '?' -> privateMode = true
                '>', '<', '=', '!' -> Unit
                in ' '..'/' -> intermediate = ch
                else -> {
                    dispatchCSI(ch)
                    state = STATE_GROUND
                }
            }
        }
    }

    private fun dispatchCSI(command: Char) {
        val raw = params.toString()
        val numbers = if (raw.isEmpty()) {
            emptyList()
        } else {
            raw.split(';').map { it.toIntOrNull() ?: 0 }
        }
        fun arg(index: Int, default: Int = 1) = numbers.getOrNull(index) ?: default

        when (command) {
            'A' -> cursorRow = max(scrollTop, cursorRow - arg(0))
            'B' -> cursorRow = min(scrollBottom, cursorRow + arg(0))
            'C' -> cursorCol = min(cols - 1, cursorCol + arg(0))
            'D' -> cursorCol = max(0, cursorCol - arg(0))
            'E' -> { cursorRow = min(scrollBottom, cursorRow + arg(0)); cursorCol = 0 }
            'F' -> { cursorRow = max(scrollTop, cursorRow - arg(0)); cursorCol = 0 }
            'G', '`' -> cursorCol = min(cols - 1, max(0, arg(0, 1) - 1))
            'd' -> cursorRow = min(scrollBottom, max(0, arg(0, 1) - 1))
            'H', 'f' -> {
                cursorRow = min(rows - 1, max(0, arg(0, 1) - 1))
                cursorCol = min(cols - 1, max(0, arg(1, 1) - 1))
            }
            'J' -> eraseInDisplay(arg(0, 0))
            'K' -> eraseInLine(arg(0, 0))
            'L' -> insertLines(arg(0))
            'M' -> deleteLines(arg(0))
            'P' -> deleteCharacters(arg(0))
            '@' -> insertCharacters(arg(0))
            'S' -> scrollUp(arg(0))
            'T' -> scrollDown(arg(0))
            's' -> { savedRow = cursorRow; savedCol = cursorCol }
            'u' -> { cursorRow = savedRow; cursorCol = savedCol }
            'r' -> {
                val top = max(0, arg(0, 1) - 1)
                val bottom = min(rows - 1, arg(1, rows) - 1)
                if (top < bottom) {
                    scrollTop = top
                    scrollBottom = bottom
                    cursorRow = scrollTop
                    cursorCol = 0
                }
            }
            'm' -> applySGR(numbers)
            'h' -> if (privateMode) setPrivateMode(numbers, enabled = true)
            'l' -> if (privateMode) setPrivateMode(numbers, enabled = false)
            else -> Unit
        }
    }

    private fun put(ch: Char) {
        if (cursorCol >= cols) {
            cursorCol = 0
            newLine()
        }
        val index = cursorRow * cols + cursorCol
        if (index in chars.indices) {
            chars[index] = ch
            fgColors[index] = currentFg
            bgColors[index] = currentBg
            flags[index] = currentFlags
        }
        cursorCol++
    }

    private fun newLine() {
        if (cursorRow == scrollBottom) {
            scrollUp(1)
        } else if (cursorRow < rows - 1) {
            cursorRow++
        }
    }

    private fun reverseIndex() {
        if (cursorRow == scrollTop) {
            scrollDown(1)
        } else if (cursorRow > 0) {
            cursorRow--
        }
    }

    private fun scrollUp(count: Int) {
        for (n in 0 until count) {
            val topLine = copyLine(scrollTop)
            if (scrollTop == 0 && topLine.any { it != ' ' }) {
                scrollback.addLast(topLine)
                if (scrollback.size > scrollbackLimit) scrollback.removeFirst()
            }
            for (row in scrollTop until scrollBottom) {
                copyRow(row + 1, row)
            }
            clearRow(scrollBottom)
        }
    }

    private fun scrollDown(count: Int) {
        for (n in 0 until count) {
            for (row in scrollBottom downTo scrollTop + 1) {
                copyRow(row - 1, row)
            }
            clearRow(scrollTop)
        }
    }

    private fun copyRow(from: Int, to: Int) {
        if (from !in 0 until rows || to !in 0 until rows) return
        System.arraycopy(chars, from * cols, chars, to * cols, cols)
        System.arraycopy(fgColors, from * cols, fgColors, to * cols, cols)
        System.arraycopy(bgColors, from * cols, bgColors, to * cols, cols)
        System.arraycopy(flags, from * cols, flags, to * cols, cols)
    }

    private fun copyLine(row: Int): CharArray = CharArray(cols) { col -> chars[row * cols + col] }

    private fun clearRow(row: Int) {
        val start = row * cols
        for (col in 0 until cols) {
            chars[start + col] = ' '
            fgColors[start + col] = DEFAULT_FG
            bgColors[start + col] = DEFAULT_BG
            flags[start + col] = 0
        }
    }

    private fun eraseInDisplay(mode: Int) {
        when (mode) {
            0 -> {
                for (col in cursorCol until cols) clearCell(cursorRow, col)
                for (row in cursorRow + 1..scrollBottom) clearRow(row)
            }
            1 -> {
                for (row in scrollTop until cursorRow) clearRow(row)
                for (col in 0..cursorCol) clearCell(cursorRow, col)
            }
            2, 3 -> for (row in scrollTop..scrollBottom) clearRow(row)
        }
    }

    private fun eraseInLine(mode: Int) {
        when (mode) {
            0 -> for (col in cursorCol until cols) clearCell(cursorRow, col)
            1 -> for (col in 0..cursorCol) clearCell(cursorRow, col)
            2 -> clearRow(cursorRow)
        }
    }

    private fun clearCell(row: Int, col: Int) {
        val index = index(row, col) ?: return
        chars[index] = ' '
        fgColors[index] = DEFAULT_FG
        bgColors[index] = DEFAULT_BG
        flags[index] = 0
    }

    private fun insertLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        for (n in 0 until count) {
            for (row in scrollBottom downTo cursorRow + 1) copyRow(row - 1, row)
            clearRow(cursorRow)
        }
    }

    private fun deleteLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        for (n in 0 until count) {
            for (row in cursorRow until scrollBottom) copyRow(row + 1, row)
            clearRow(scrollBottom)
        }
    }

    private fun deleteCharacters(count: Int) {
        val row = cursorRow
        for (col in cursorCol until cols) {
            val source = col + count
            if (source < cols) {
                chars[row * cols + col] = chars[row * cols + source]
                fgColors[row * cols + col] = fgColors[row * cols + source]
                bgColors[row * cols + col] = bgColors[row * cols + source]
                flags[row * cols + col] = flags[row * cols + source]
            } else {
                clearCell(row, col)
            }
        }
    }

    private fun insertCharacters(count: Int) {
        val row = cursorRow
        for (col in cols - 1 downTo cursorCol + count) {
            val source = col - count
            if (source >= cursorCol) {
                chars[row * cols + col] = chars[row * cols + source]
                fgColors[row * cols + col] = fgColors[row * cols + source]
                bgColors[row * cols + col] = bgColors[row * cols + source]
                flags[row * cols + col] = flags[row * cols + source]
            }
        }
        for (col in cursorCol until min(cols, cursorCol + count)) clearCell(row, col)
    }

    private fun applySGR(numbers: List<Int>) {
        if (numbers.isEmpty()) {
            currentFg = DEFAULT_FG
            currentBg = DEFAULT_BG
            currentFlags = 0
            return
        }
        var index = 0
        while (index < numbers.size) {
            when (val value = numbers[index]) {
                0 -> {
                    currentFg = DEFAULT_FG
                    currentBg = DEFAULT_BG
                    currentFlags = 0
                }
                1 -> currentFlags = currentFlags or FLAG_BOLD
                2 -> currentFlags = currentFlags or FLAG_DIM
                3 -> currentFlags = currentFlags or FLAG_ITALIC
                4 -> currentFlags = currentFlags or FLAG_UNDERLINE
                7 -> currentFlags = currentFlags or FLAG_REVERSE
                22 -> currentFlags = currentFlags and (FLAG_BOLD or FLAG_DIM).inv()
                23 -> currentFlags = currentFlags and FLAG_ITALIC.inv()
                24 -> currentFlags = currentFlags and FLAG_UNDERLINE.inv()
                27 -> currentFlags = currentFlags and FLAG_REVERSE.inv()
                in 30..37 -> currentFg = value - 30
                38 -> {
                    // Extended colour: only the 256-colour form is parsed; the
                    // truecolor form is consumed and mapped to the nearest index.
                    when (numbers.getOrNull(index + 1)) {
                        5 -> { currentFg = numbers.getOrNull(index + 2) ?: DEFAULT_FG; index += 2 }
                        2 -> {
                            val r = numbers.getOrNull(index + 2) ?: 0
                            val g = numbers.getOrNull(index + 3) ?: 0
                            val b = numbers.getOrNull(index + 4) ?: 0
                            currentFg = rgbToIndex(r, g, b)
                            index += 4
                        }
                    }
                }
                39 -> currentFg = DEFAULT_FG
                in 40..47 -> currentBg = value - 40
                48 -> {
                    when (numbers.getOrNull(index + 1)) {
                        5 -> { currentBg = numbers.getOrNull(index + 2) ?: DEFAULT_BG; index += 2 }
                        2 -> {
                            val r = numbers.getOrNull(index + 2) ?: 0
                            val g = numbers.getOrNull(index + 3) ?: 0
                            val b = numbers.getOrNull(index + 4) ?: 0
                            currentBg = rgbToIndex(r, g, b)
                            index += 4
                        }
                    }
                }
                49 -> currentBg = DEFAULT_BG
                in 90..97 -> currentFg = value - 90 + 8
                in 100..107 -> currentBg = value - 100 + 8
            }
            index++
        }
    }

    private fun rgbToIndex(r: Int, g: Int, b: Int): Int {
        if (r == g && g == b) {
            val grey = 232 + (r * 23 / 255)
            return grey.coerceIn(232, 255)
        }
        val ri = (r * 5 / 255).coerceIn(0, 5)
        val gi = (g * 5 / 255).coerceIn(0, 5)
        val bi = (b * 5 / 255).coerceIn(0, 5)
        return 16 + 36 * ri + 6 * gi + bi
    }

    private fun setPrivateMode(numbers: List<Int>, enabled: Boolean) {
        for (value in numbers) {
            when (value) {
                25 -> cursorVisible = enabled
                1049, 47, 1047 -> {
                    if (enabled && !inAltScreen) enterAltScreen()
                    else if (!enabled && inAltScreen) leaveAltScreen()
                }
            }
        }
    }

    private fun enterAltScreen() {
        altChars = chars.copyOf()
        altFg = fgColors.copyOf()
        altBg = bgColors.copyOf()
        altFlags = flags.copyOf()
        for (row in 0 until rows) clearRow(row)
        inAltScreen = true
    }

    private fun leaveAltScreen() {
        altChars?.let { chars = it }
        altFg?.let { fgColors = it }
        altBg?.let { bgColors = it }
        altFlags?.let { flags = it }
        altChars = null; altFg = null; altBg = null; altFlags = null
        inAltScreen = false
    }

    // MARK: - Sizing

    fun resize(newCols: Int, newRows: Int) {
        val c = max(1, newCols)
        val r = max(1, newRows)
        if (c == cols && r == rows) return

        val newChars = CharArray(c * r) { ' ' }
        val newFg = IntArray(c * r) { DEFAULT_FG }
        val newBg = IntArray(c * r) { DEFAULT_BG }
        val newFlags = IntArray(c * r)

        val copyRows = min(rows, r)
        val copyCols = min(cols, c)
        for (row in 0 until copyRows) {
            for (col in 0 until copyCols) {
                newChars[row * c + col] = chars[row * cols + col]
                newFg[row * c + col] = fgColors[row * cols + col]
                newBg[row * c + col] = bgColors[row * cols + col]
                newFlags[row * c + col] = flags[row * cols + col]
            }
        }

        chars = newChars
        fgColors = newFg
        bgColors = newBg
        flags = newFlags
        cols = c
        rows = r
        scrollTop = 0
        scrollBottom = r - 1
        cursorRow = min(cursorRow, r - 1)
        cursorCol = min(cursorCol, c - 1)
        version++
    }

    fun reset() {
        for (row in 0 until rows) clearRow(row)
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        currentFg = DEFAULT_FG
        currentBg = DEFAULT_BG
        currentFlags = 0
        if (inAltScreen) leaveAltScreen()
        version++
    }

    /** Plain text of the viewport, for copy and for the doctor's evidence dump. */
    fun text(): String = buildString {
        for (row in 0 until rows) {
            for (col in 0 until cols) append(charAt(row, col))
            if (row < rows - 1) append('\n')
        }
    }
}
