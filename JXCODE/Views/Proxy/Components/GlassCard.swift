import SwiftUI

// MARK: - Glass Card
// From JXRouter — card container with optional header + icon.

struct GlassCard<Content: View>: View {
    let content: Content
    var header: String? = nil
    var headerIcon: String? = nil
    var accentColor: Color = .jxAccent

    init(
        header: String? = nil,
        headerIcon: String? = nil,
        accentColor: Color = .jxAccent,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.headerIcon = headerIcon
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JXSpacing.md) {
            if let header {
                HStack(spacing: JXSpacing.sm) {
                    if let icon = headerIcon {
                        Image(systemName: icon)
                            .font(JXFont.jb(JXFont.default, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }
                    Text(header)
                        .font(JXFont.subheading)
                        .foregroundStyle(Color.jxTextPrimary)
                }
            }

            content
        }
        .jxCardStyle()
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .jxAccent
    var trend: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: JXSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(JXFont.jb(10, weight: .medium))
                    .foregroundStyle(color)
                Text(title)
                    .font(JXFont.caption)
                    .foregroundStyle(Color.jxTextSecondary)
            }

            Text(value)
                .font(JXFont.statValue)
                .foregroundStyle(Color.jxTextPrimary)

            if let trend {
                Text(trend)
                    .font(JXFont.caption)
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(JXSpacing.md)
        .background(Color.jxBackgroundTertiary, in: RoundedRectangle(cornerRadius: JXRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: JXRadius.md)
                .stroke(Color.jxSurfaceBorder.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Toast Overlay

struct ToastModifier: ViewModifier {
    let message: String?
    let type: ToastType

    enum ToastType { case info, success, error, warning }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    HStack(spacing: JXSpacing.sm) {
                        Image(systemName: icon)
                            .foregroundStyle(Color.jxTextPrimary)
                        Text(message)
                            .font(JXFont.body)
                            .foregroundStyle(Color.jxTextPrimary)
                    }
                    .padding(.horizontal, JXSpacing.lg)
                    .padding(.vertical, JXSpacing.md)
                    .background(fillColor, in: RoundedRectangle(cornerRadius: JXRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: JXRadius.md)
                            .stroke(Color.jxSurfaceBorder.opacity(0.3), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: message)
                }
            }
    }

    private var icon: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var fillColor: Color {
        switch type {
        case .success: return Color.jxOnline.opacity(0.9)
        case .error: return Color.jxOffline.opacity(0.9)
        case .warning: return Color.jxWarning.opacity(0.9)
        case .info: return Color.jxAccentSecondary.opacity(0.9)
        }
    }
}
