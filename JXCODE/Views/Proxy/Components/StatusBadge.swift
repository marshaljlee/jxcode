import SwiftUI

// MARK: - Status Badge
// From JXRouter — status indicator for proxy state.

struct StatusBadge: View {
    let status: ProxyStatus

    private var color: Color {
        switch status {
        case .running: return Color.jxOnline
        case .starting, .stopping: return Color.jxWarning
        case .failed: return Color.jxOffline
        case .stopped: return Color.jxIdle
        }
    }

    private var icon: String {
        switch status {
        case .running: return "circle.fill"
        case .starting: return "arrow.triangle.2.circlepath"
        case .stopping: return "stop.circle"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped: return "circle"
        }
    }

    var body: some View {
        HStack(spacing: JXSpacing.sm) {
            Image(systemName: icon)
                .font(JXFont.jb(10))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .jxAccentGlow(radius: 4)

            Text(status.label)
                .font(JXFont.subheading)
                .foregroundStyle(Color.jxTextPrimary)
        }
        .padding(.vertical, JXSpacing.xs)
    }
}

// MARK: - Routing Status Badge

struct RoutingStatusBadge: View {
    let status: RoutingApp.RoutingStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(JXFont.caption)
                .foregroundStyle(Color.jxTextSecondary)
        }
        .padding(.horizontal, JXSpacing.sm)
        .padding(.vertical, 3)
        .background(statusBg, in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch status {
        case .routed: return Color.jxOnline
        case .detected: return Color.jxWarning
        case .ignored: return Color.jxIdle
        case .blocked: return Color.jxOffline
        case .unknown: return Color.jxTextTertiary
        }
    }

    private var statusBg: Color {
        color.opacity(0.12)
    }
}
