import SwiftUI

// MARK: - Theme Colors Definition

public struct ThemeColors: @unchecked Sendable {
    public let accent: Color
    public let accentSubtle: Color
    public let background: Color
    public let surfacePrimary: Color
    public let surfaceSecondary: Color
    public let surfaceTertiary: Color
    public let surfaceElevated: Color
    public let sidebarBackground: Color
    public let sidebarItemHover: Color
    public let sidebarItemSelected: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let border: Color
    public let borderSubtle: Color
    public let codeBackground: Color
    public let codeHeaderBackground: Color
    public let userBubble: Color
    public let userBubbleText: Color
    public let assistantBubble: Color
    public let statusSuccess: Color
    public let statusError: Color
    public let statusWarning: Color
    public let inputBackground: Color
    public let inputBorder: Color

    public init(
        accent: Color, accentSubtle: Color,
        background: Color, surfacePrimary: Color, surfaceSecondary: Color,
        surfaceTertiary: Color, surfaceElevated: Color,
        sidebarBackground: Color, sidebarItemHover: Color, sidebarItemSelected: Color,
        textPrimary: Color, textSecondary: Color, textTertiary: Color,
        border: Color, borderSubtle: Color,
        codeBackground: Color, codeHeaderBackground: Color,
        userBubble: Color, userBubbleText: Color, assistantBubble: Color,
        statusSuccess: Color, statusError: Color, statusWarning: Color,
        inputBackground: Color, inputBorder: Color
    ) {
        self.accent = accent
        self.accentSubtle = accentSubtle
        self.background = background
        self.surfacePrimary = surfacePrimary
        self.surfaceSecondary = surfaceSecondary
        self.surfaceTertiary = surfaceTertiary
        self.surfaceElevated = surfaceElevated
        self.sidebarBackground = sidebarBackground
        self.sidebarItemHover = sidebarItemHover
        self.sidebarItemSelected = sidebarItemSelected
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.border = border
        self.borderSubtle = borderSubtle
        self.codeBackground = codeBackground
        self.codeHeaderBackground = codeHeaderBackground
        self.userBubble = userBubble
        self.userBubbleText = userBubbleText
        self.assistantBubble = assistantBubble
        self.statusSuccess = statusSuccess
        self.statusError = statusError
        self.statusWarning = statusWarning
        self.inputBackground = inputBackground
        self.inputBorder = inputBorder
    }

    // Computed shorthands
    public var textOnAccent: Color { .white }
    public var inputPlaceholder: Color { textTertiary }
    public var statusRunning: Color { accent }
}

// MARK: - Claude Theme (warm terracotta)

extension ThemeColors {
    public static let claude: ThemeColors = {
        let accent = Color.hex(0x0A84FF)
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color.hex(0x0A84FF, opacity: 0.15),
            background:           Color.hex(0x151718),
            surfacePrimary:       Color.hex(0x1E2022),
            surfaceSecondary:     Color.hex(0x181A1C),
            surfaceTertiary:      Color.hex(0x121314),
            surfaceElevated:      Color.hex(0x222426),
            sidebarBackground:    Color.hex(0x0B0C0E),
            sidebarItemHover:     Color.hex(0x181A1C),
            sidebarItemSelected:  Color.hex(0x0A84FF, opacity: 0.15),
            textPrimary:          Color.hex(0xE4E6EB),
            textSecondary:        Color.hex(0x9BA1A6),
            textTertiary:         Color.hex(0x5C6066),
            border:               Color.hex(0x232527),
            borderSubtle:         Color.hex(0x1E2022),
            codeBackground:       Color.hex(0x181A1C),
            codeHeaderBackground: Color.hex(0x121314),
            userBubble:           Color.hex(0x1E2022),
            userBubbleText:       Color.hex(0x88C0D0),
            assistantBubble:      Color.hex(0x151718),
            statusSuccess:        Color.hex(0x38B000),
            statusError:          Color.hex(0xFF3B30),
            statusWarning:        Color.hex(0xFFCC00),
            inputBackground:      Color.hex(0x1E2022),
            inputBorder:          Color.hex(0x232527)
        )
    }()
}

extension ThemeColors {
    public static let ocean: ThemeColors = {
        let accent: Color = Color(light: .hex(0x2E8BC0), dark: .hex(0x4CA8D4))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x2E8BC0).opacity(0.12), dark: .hex(0x4CA8D4).opacity(0.15)),
            background:           Color(light: .hex(0xF0F4F8), dark: .hex(0x111C27)),
            surfacePrimary:       Color(light: .hex(0xE7EEF5), dark: .hex(0x182433)),
            surfaceSecondary:     Color(light: .hex(0xDBE5EF), dark: .hex(0x1F2F41)),
            surfaceTertiary:      Color(light: .hex(0xCEDCE9), dark: .hex(0x273B50)),
            surfaceElevated:      Color(light: .hex(0xF6F9FC), dark: .hex(0x1A2D3E)),
            sidebarBackground:    Color(light: .hex(0xE3ECF4), dark: .hex(0x0D1820)),
            sidebarItemHover:     Color(light: .hex(0xD5E2EE), dark: .hex(0x182433)),
            sidebarItemSelected:  Color(light: .hex(0x2E8BC0).opacity(0.12), dark: .hex(0x4CA8D4).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x192B3C), dark: .hex(0xC5D5E5)),
            textSecondary:        Color(light: .hex(0x476480), dark: .hex(0x7898B5)),
            textTertiary:         Color(light: .hex(0x7896AF), dark: .hex(0x527090)),
            border:               Color(light: .hex(0xC4D4E2), dark: .hex(0x2A3D52)),
            borderSubtle:         Color(light: .hex(0xD5E2EE), dark: .hex(0x1F2F41)),
            codeBackground:       Color(light: .hex(0xE0EBF3), dark: .hex(0x0C1722)),
            codeHeaderBackground: Color(light: .hex(0xD2E4EF), dark: .hex(0x132030)),
            userBubble:           Color(light: .hex(0x192B3C), dark: .hex(0x273B50)),
            userBubbleText:       Color(light: .hex(0xF0F4F8), dark: .hex(0xC5D5E5)),
            assistantBubble:      Color(light: .hex(0xE0EBF3), dark: .hex(0x182433)),
            statusSuccess:        Color(light: .hex(0x3A8A5E), dark: .hex(0x5A9E7A)),
            statusError:          Color(light: .hex(0xC0504A), dark: .hex(0xC46D64)),
            statusWarning:        Color(light: .hex(0xBF8530), dark: .hex(0xD4A050)),
            inputBackground:      Color(light: .hex(0xF6F9FC), dark: .hex(0x182433)),
            inputBorder:          Color(light: .hex(0xC4D4E2), dark: .hex(0x2A3D52))
        )
    }()
}

extension ThemeColors {
    public static let forest: ThemeColors = {
        let accent: Color = Color(light: .hex(0x2E7D52), dark: .hex(0x4DAA73))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x2E7D52).opacity(0.12), dark: .hex(0x4DAA73).opacity(0.15)),
            background:           Color(light: .hex(0xF0F5F1), dark: .hex(0x0F1E16)),
            surfacePrimary:       Color(light: .hex(0xE6EEE8), dark: .hex(0x162518)),
            surfaceSecondary:     Color(light: .hex(0xDAE5DC), dark: .hex(0x1E3022)),
            surfaceTertiary:      Color(light: .hex(0xCEDDD1), dark: .hex(0x253D2A)),
            surfaceElevated:      Color(light: .hex(0xF7FAF8), dark: .hex(0x1A2F1E)),
            sidebarBackground:    Color(light: .hex(0xE3EDE5), dark: .hex(0x0C1912)),
            sidebarItemHover:     Color(light: .hex(0xD6E5D9), dark: .hex(0x162518)),
            sidebarItemSelected:  Color(light: .hex(0x2E7D52).opacity(0.12), dark: .hex(0x4DAA73).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x1A3328), dark: .hex(0xB8D4C2)),
            textSecondary:        Color(light: .hex(0x456B55), dark: .hex(0x7AA88A)),
            textTertiary:         Color(light: .hex(0x6B9078), dark: .hex(0x5A7D68)),
            border:               Color(light: .hex(0xC0D4C6), dark: .hex(0x2A3D30)),
            borderSubtle:         Color(light: .hex(0xD6E5D9), dark: .hex(0x1E3022)),
            codeBackground:       Color(light: .hex(0xDCE9DF), dark: .hex(0x0A160D)),
            codeHeaderBackground: Color(light: .hex(0xCEDDD1), dark: .hex(0x102015)),
            userBubble:           Color(light: .hex(0x1A3328), dark: .hex(0x253D2A)),
            userBubbleText:       Color(light: .hex(0xF0F5F1), dark: .hex(0xB8D4C2)),
            assistantBubble:      Color(light: .hex(0xDCE9DF), dark: .hex(0x162518)),
            statusSuccess:        Color(light: .hex(0x2E7D52), dark: .hex(0x4DAA73)),
            statusError:          Color(light: .hex(0xB85C50), dark: .hex(0xC47060)),
            statusWarning:        Color(light: .hex(0xC78A40), dark: .hex(0xD9A757)),
            inputBackground:      Color(light: .hex(0xF7FAF8), dark: .hex(0x162518)),
            inputBorder:          Color(light: .hex(0xC0D4C6), dark: .hex(0x2A3D30))
        )
    }()
}

extension ThemeColors {
    public static let lavender: ThemeColors = {
        let accent: Color = Color(light: .hex(0x7B5EA7), dark: .hex(0x9B7EC8))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x7B5EA7).opacity(0.12), dark: .hex(0x9B7EC8).opacity(0.15)),
            background:           Color(light: .hex(0xF4F2F8), dark: .hex(0x16111E)),
            surfacePrimary:       Color(light: .hex(0xEBE8F5), dark: .hex(0x1E1828)),
            surfaceSecondary:     Color(light: .hex(0xE0DBF0), dark: .hex(0x271F33)),
            surfaceTertiary:      Color(light: .hex(0xD4CEEA), dark: .hex(0x31273F)),
            surfaceElevated:      Color(light: .hex(0xF9F8FC), dark: .hex(0x211B2E)),
            sidebarBackground:    Color(light: .hex(0xE8E5F3), dark: .hex(0x110E18)),
            sidebarItemHover:     Color(light: .hex(0xDDD9EE), dark: .hex(0x1E1828)),
            sidebarItemSelected:  Color(light: .hex(0x7B5EA7).opacity(0.12), dark: .hex(0x9B7EC8).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x2C2040), dark: .hex(0xC8BDE0)),
            textSecondary:        Color(light: .hex(0x5E4D80), dark: .hex(0x8878B0)),
            textTertiary:         Color(light: .hex(0x8B7AAC), dark: .hex(0x614F88)),
            border:               Color(light: .hex(0xC8C0E0), dark: .hex(0x352A48)),
            borderSubtle:         Color(light: .hex(0xDDD9EE), dark: .hex(0x271F33)),
            codeBackground:       Color(light: .hex(0xE2DDEF), dark: .hex(0x100C18)),
            codeHeaderBackground: Color(light: .hex(0xD6D0EA), dark: .hex(0x171121)),
            userBubble:           Color(light: .hex(0x2C2040), dark: .hex(0x31273F)),
            userBubbleText:       Color(light: .hex(0xF4F2F8), dark: .hex(0xC8BDE0)),
            assistantBubble:      Color(light: .hex(0xE2DDEF), dark: .hex(0x1E1828)),
            statusSuccess:        Color(light: .hex(0x4A8A6A), dark: .hex(0x6AAC88)),
            statusError:          Color(light: .hex(0xB85C50), dark: .hex(0xC47060)),
            statusWarning:        Color(light: .hex(0xC78A40), dark: .hex(0xD9A757)),
            inputBackground:      Color(light: .hex(0xF9F8FC), dark: .hex(0x1E1828)),
            inputBorder:          Color(light: .hex(0xC8C0E0), dark: .hex(0x352A48))
        )
    }()
}

extension ThemeColors {
    public static let amber: ThemeColors = {
        let accent: Color = Color(light: .hex(0xBF8A10), dark: .hex(0xE0AC30))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0xBF8A10).opacity(0.12), dark: .hex(0xE0AC30).opacity(0.15)),
            background:           Color(light: .hex(0xF8F5EC), dark: .hex(0x1C1800)),
            surfacePrimary:       Color(light: .hex(0xF0EAD8), dark: .hex(0x261E04)),
            surfaceSecondary:     Color(light: .hex(0xE6E0C8), dark: .hex(0x30280A)),
            surfaceTertiary:      Color(light: .hex(0xDAD4B8), dark: .hex(0x3C3310)),
            surfaceElevated:      Color(light: .hex(0xFCFAF4), dark: .hex(0x2A2208)),
            sidebarBackground:    Color(light: .hex(0xEDE7D2), dark: .hex(0x151200)),
            sidebarItemHover:     Color(light: .hex(0xE2DBC6), dark: .hex(0x261E04)),
            sidebarItemSelected:  Color(light: .hex(0xBF8A10).opacity(0.12), dark: .hex(0xE0AC30).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x3A2C06), dark: .hex(0xD4C47A)),
            textSecondary:        Color(light: .hex(0x7A6028), dark: .hex(0xA08840)),
            textTertiary:         Color(light: .hex(0xA89050), dark: .hex(0x756430)),
            border:               Color(light: .hex(0xD4CBA0), dark: .hex(0x3A2E10)),
            borderSubtle:         Color(light: .hex(0xE2DBC6), dark: .hex(0x30280A)),
            codeBackground:       Color(light: .hex(0xEAE3CC), dark: .hex(0x110E00)),
            codeHeaderBackground: Color(light: .hex(0xDED7C0), dark: .hex(0x1C1800)),
            userBubble:           Color(light: .hex(0x3A2C06), dark: .hex(0x3C3310)),
            userBubbleText:       Color(light: .hex(0xF8F5EC), dark: .hex(0xD4C47A)),
            assistantBubble:      Color(light: .hex(0xEAE3CC), dark: .hex(0x261E04)),
            statusSuccess:        Color(light: .hex(0x4A8A5E), dark: .hex(0x6AAC7C)),
            statusError:          Color(light: .hex(0xB85C50), dark: .hex(0xC47060)),
            statusWarning:        Color(light: .hex(0xBF8A10), dark: .hex(0xE0AC30)),
            inputBackground:      Color(light: .hex(0xFCFAF4), dark: .hex(0x261E04)),
            inputBorder:          Color(light: .hex(0xD4CBA0), dark: .hex(0x3A2E10))
        )
    }()
}

extension ThemeColors {
    public static let midnight: ThemeColors = {
        let accent: Color = Color(light: .hex(0x4A5CC7), dark: .hex(0x6B7FD4))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x4A5CC7).opacity(0.12), dark: .hex(0x6B7FD4).opacity(0.15)),
            background:           Color(light: .hex(0xF0F1F8), dark: .hex(0x0E0F1C)),
            surfacePrimary:       Color(light: .hex(0xE7E9F5), dark: .hex(0x151827)),
            surfaceSecondary:     Color(light: .hex(0xDCDFF0), dark: .hex(0x1C2033)),
            surfaceTertiary:      Color(light: .hex(0xD0D4EA), dark: .hex(0x232740)),
            surfaceElevated:      Color(light: .hex(0xF6F7FB), dark: .hex(0x191C30)),
            sidebarBackground:    Color(light: .hex(0xE3E5F2), dark: .hex(0x0A0B16)),
            sidebarItemHover:     Color(light: .hex(0xD8DBEE), dark: .hex(0x151827)),
            sidebarItemSelected:  Color(light: .hex(0x4A5CC7).opacity(0.12), dark: .hex(0x6B7FD4).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x1A1E40), dark: .hex(0xBBC4E8)),
            textSecondary:        Color(light: .hex(0x4A5080), dark: .hex(0x6872A8)),
            textTertiary:         Color(light: .hex(0x7078A8), dark: .hex(0x4A5080)),
            border:               Color(light: .hex(0xC0C6E0), dark: .hex(0x272D48)),
            borderSubtle:         Color(light: .hex(0xD8DBEE), dark: .hex(0x1C2033)),
            codeBackground:       Color(light: .hex(0xDBDEF0), dark: .hex(0x09091A)),
            codeHeaderBackground: Color(light: .hex(0xCDD1EC), dark: .hex(0x0F1024)),
            userBubble:           Color(light: .hex(0x1A1E40), dark: .hex(0x232740)),
            userBubbleText:       Color(light: .hex(0xF0F1F8), dark: .hex(0xBBC4E8)),
            assistantBubble:      Color(light: .hex(0xDBDEF0), dark: .hex(0x151827)),
            statusSuccess:        Color(light: .hex(0x3A8A5E), dark: .hex(0x5AAC7A)),
            statusError:          Color(light: .hex(0xB85C50), dark: .hex(0xC47060)),
            statusWarning:        Color(light: .hex(0xC78A40), dark: .hex(0xD9A757)),
            inputBackground:      Color(light: .hex(0xF6F7FB), dark: .hex(0x151827)),
            inputBorder:          Color(light: .hex(0xC0C6E0), dark: .hex(0x272D48))
        )
    }()
}

extension ThemeColors {
    public static let brainwave: ThemeColors = {
        // Neon brainwave / EEG visualization palette:
        // electric cyan accent on deep navy with teal/purple complements
        let accent: Color = Color.hex(0x00D4FF) // electric cyan
        return ThemeColors(
            accent:               accent,
            accentSubtle:         accent.opacity(0.15),
            background:           Color.hex(0x050B14), // deep navy black
            surfacePrimary:       Color.hex(0x0C1522),
            surfaceSecondary:     Color.hex(0x111D30),
            surfaceTertiary:      Color.hex(0x0A121E),
            surfaceElevated:      Color.hex(0x15233A),
            sidebarBackground:    Color.hex(0x03070E),
            sidebarItemHover:     Color.hex(0x0C1522),
            sidebarItemSelected:  accent.opacity(0.15),
            textPrimary:          Color.hex(0xE0E8F0),
            textSecondary:        Color.hex(0x8098B8),
            textTertiary:         Color.hex(0x4A6588),
            border:               Color.hex(0x1A2A42),
            borderSubtle:         Color.hex(0x111D30),
            codeBackground:       Color.hex(0x0A121E),
            codeHeaderBackground: Color.hex(0x050A14),
            userBubble:           Color.hex(0x15233A),
            userBubbleText:       Color.hex(0x00D4FF), // electric cyan
            assistantBubble:      Color.hex(0x0C1522),
            statusSuccess:        Color.hex(0x00E5B0), // bright teal
            statusError:          Color.hex(0xFF4060), // coral
            statusWarning:        Color.hex(0xFFB020), // warm amber
            inputBackground:      Color.hex(0x0C1522),
            inputBorder:          Color.hex(0x1A2A42)
        )
    }()
}

extension ThemeColors {
    public static let brainwaveLight: ThemeColors = {
        // Light counterpart: icy blue-white foundations with electric cyan accent,
        // deep navy user bubble echoing the dark brainwave palette
        return ThemeColors(
            accent:               Color.hex(0x0088CC), // deeper cyan for light mode contrast
            accentSubtle:         Color.hex(0x0088CC, opacity: 0.10),
            background:           Color.hex(0xF0F4FA), // icy blue-white
            surfacePrimary:       Color.hex(0xE8EEF6),
            surfaceSecondary:     Color.hex(0xE0E8F2),
            surfaceTertiary:      Color.hex(0xD8E2EE),
            surfaceElevated:      Color.hex(0xF6FAFF),
            sidebarBackground:    Color.hex(0xE0E8F2),
            sidebarItemHover:     Color.hex(0xD8E2EE),
            sidebarItemSelected:  Color.hex(0x0088CC, opacity: 0.08),
            textPrimary:          Color.hex(0x0A1420),
            textSecondary:        Color.hex(0x406080),
            textTertiary:         Color.hex(0x7090B0),
            border:               Color.hex(0xC0D0E0),
            borderSubtle:         Color.hex(0xD8E2EE),
            codeBackground:       Color.hex(0xE0EAF4),
            codeHeaderBackground: Color.hex(0xD4E0EE),
            userBubble:           Color.hex(0x0A1420),
            userBubbleText:       Color.hex(0xE0E8F0),
            assistantBubble:      Color.hex(0xE0EAF4),
            statusSuccess:        Color.hex(0x00997A), // teal
            statusError:          Color.hex(0xD0404A), // red
            statusWarning:        Color.hex(0xD09020), // amber
            inputBackground:      Color.hex(0xF6FAFF),
            inputBorder:          Color.hex(0xC0D0E0)
        )
    }()
}

// MARK: - App Theme Enum

public enum AppTheme: String, CaseIterable, Identifiable {
    case claude       = "Terracotta"
    case ocean        = "Ocean"
    case forest       = "Forest"
    case lavender     = "Lavender"
    case midnight     = "Midnight"
    case amber        = "Amber"
    case brainwaveDark  = "Brainwave (Dark)"
    case brainwaveLight = "Brainwave (Light)"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude:   "Terracotta (Default)"
        case .ocean:    "Ocean (Blue)"
        case .forest:   "Forest (Green)"
        case .lavender: "Lavender (Purple)"
        case .midnight: "Midnight (Indigo)"
        case .amber:    "Amber (Yellow)"
        case .brainwaveDark: "Brainwave (Dark)"
        case .brainwaveLight: "Brainwave (Light)"
        }
    }

    public var colors: ThemeColors {
        switch self {
        case .claude:   .claude
        case .ocean:    .ocean
        case .forest:   .forest
        case .lavender: .lavender
        case .midnight: .midnight
        case .amber:    .amber
        case .brainwaveDark: .brainwave
        case .brainwaveLight: .brainwaveLight
        }
    }
}

// MARK: - Theme Store

public extension Notification.Name {
    static let jxcodeThemeDidChange = Notification.Name("com.idealapp.jxcode.themeDidChange")
}

@MainActor
public final class ThemeStore {
    public static let shared = ThemeStore()
    private init() {}

    public var current: AppTheme = .claude {
        didSet {
            colors = current.colors
            NotificationCenter.default.post(name: .jxcodeThemeDidChange, object: nil)
        }
    }
    public var colors: ThemeColors = .claude

    /// Absolute interface font size (default 12). Affects all labels, buttons, tooltips.
    public var interfaceFontSize: CGFloat = 12 {
        didSet { NotificationCenter.default.post(name: .jxcodeThemeDidChange, object: nil) }
    }
    /// Absolute message content font size (default 12). Affects chat bubbles, code blocks.
    public var messageFontSize: CGFloat = 12 {
        didSet { NotificationCenter.default.post(name: .jxcodeThemeDidChange, object: nil) }
    }

    public static let minFontSize: CGFloat = 8
    public static let maxFontSize: CGFloat = 24
}
