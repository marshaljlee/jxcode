import SwiftUI

// MARK: - JX Proxy Theme
// JXRouter's color system + JetBrains Mono font integration for the proxy dashboard.

// MARK: - JetBrains Mono Font System

/// The only font used throughout the entire application.
/// Family name: "JetBrains Mono" (registered via Info.plist > ATSApplicationFontsPath).
enum JXFont {
    /// Default size for all UI elements = 12.
    static let `default`: CGFloat = 12

    /// Returns "JetBrains Mono" at the specified size with optional weight.
    static func jb(_ size: CGFloat = `default`, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }

    // Convenience named fonts matching typographic roles
    static let display = jb(20, weight: .semibold)
    static let heading = jb(15, weight: .semibold)
    static let subheading = jb(13, weight: .medium)
    static let body = jb(12, weight: .regular)
    static let bodySmall = jb(11, weight: .regular)
    static let caption = jb(10, weight: .regular)
    static let monospace = jb(11, weight: .regular)
    static let monospaceSmall = jb(10, weight: .regular)
    static let button = jb(12, weight: .medium)
    static let label = jb(10, weight: .semibold).smallCaps()
    static let statValue = jb(20, weight: .semibold)
}

extension View {
    /// Applies JetBrains Mono as the base font for this view hierarchy.
    /// Use on the root view to set the app-wide default font.
    func jxFont(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.custom("JetBrains Mono", size: size).weight(weight))
    }
}

// MARK: - Color System (OKLCH-based dark theme)

extension Color {
    // Background
    static let jxBackground = Color(oklch: 0.12, 0.012, 260)
    static let jxBackgroundSecondary = Color(oklch: 0.16, 0.015, 260)
    static let jxBackgroundTertiary = Color(oklch: 0.20, 0.018, 260)
    static let jxBackgroundElevated = Color(oklch: 0.24, 0.020, 260)

    // Surface
    static let jxSurfacePrimary = Color(oklch: 0.28, 0.025, 260)
    static let jxSurfaceSecondary = Color(oklch: 0.32, 0.028, 260)
    static let jxSurfaceBorder = Color(oklch: 0.35, 0.030, 260)

    // Accent — Electric cyan for proxy/network theme
    static let jxAccent = Color(oklch: 0.62, 0.19, 255)
    static let jxAccentSecondary = Color(oklch: 0.55, 0.16, 255)
    static let jxAccentGlow = Color(oklch: 0.62, 0.19, 255).opacity(0.3)
    static let jxAccentDim = Color(oklch: 0.62, 0.19, 255).opacity(0.12)

    // Status
    static let jxOnline = Color(oklch: 0.55, 0.18, 150)
    static let jxWarning = Color(oklch: 0.65, 0.18, 85)
    static let jxOffline = Color(oklch: 0.55, 0.22, 30)
    static let jxIdle = Color(oklch: 0.45, 0.04, 260)

    // Text
    static let jxTextPrimary = Color(oklch: 0.93, 0.010, 260)
    static let jxTextSecondary = Color(oklch: 0.65, 0.025, 260)
    static let jxTextTertiary = Color(oklch: 0.45, 0.020, 260)
    static let jxTextAccent = Color(oklch: 0.62, 0.19, 255)
    static let jxTextWarning = Color(oklch: 0.65, 0.18, 85)
    static let jxTextError = Color(oklch: 0.55, 0.22, 30)
    static let jxTextSuccess = Color(oklch: 0.55, 0.18, 150)
}

private extension Color {
    init(oklch l: Double, _ c: Double, _ h: Double, opacity: Double = 1.0) {
        let hue = h
        let saturation = min(c / 0.15 * 0.6, 0.9)
        let brightness = min(l * 0.9, 0.95)
        self.init(
            hue: hue / 360,
            saturation: saturation,
            brightness: brightness,
            opacity: opacity
        )
    }
}

// MARK: - Spacing

enum JXSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner Radius

enum JXRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 18
}

// MARK: - Shadow

enum JXShadow {
    static let card: CGFloat = 12
    static let elevated: CGFloat = 20
    static let glow: CGFloat = 8
}

// MARK: - View Extensions

extension View {
    func jxCardStyle(background: Color = .jxBackgroundElevated) -> some View {
        self
            .padding(JXSpacing.lg)
            .background(background, in: RoundedRectangle(cornerRadius: JXRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: JXRadius.lg)
                    .stroke(Color.jxSurfaceBorder.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
    }

    func jxSectionLabel() -> some View {
        self
            .font(JXFont.label)
            .foregroundStyle(Color.jxTextSecondary)
            .padding(.bottom, JXSpacing.sm)
    }

    func jxAccentGlow(radius: CGFloat = 6) -> some View {
        self
            .shadow(color: Color.jxAccentGlow, radius: radius, x: 0, y: 0)
    }
}
