import SwiftUI
import JXCODECore

struct UsageSidebarView: View {
    @State private var entries: [UsageService.UsageEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Usage Analytics")
                .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            VStack(spacing: 12) {
                statCard(title: "Today", value: todaySpend)
                statCard(title: "Last 7 Days", value: sevenDaySpend)
                statCard(title: "Last 30 Days", value: thirtyDaySpend)
            }
            .padding(.horizontal, 12)

            Spacer()
        }
        .task {
            entries = await UsageService.shared.loadAllUsage()
        }
    }

    private func statCard(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            
            Text(String(format: "$%.3f", value))
                .font(.system(size: ClaudeTheme.size(16), weight: .bold))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Calculations

    private var todaySpend: Double {
        let calendar = Calendar.current
        let today = Date()
        return entries
            .filter { calendar.isDate($0.timestamp, inSameDayAs: today) }
            .map { $0.cost }
            .reduce(0, +)
    }

    private var sevenDaySpend: Double {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return entries
            .filter { $0.timestamp >= cutoff }
            .map { $0.cost }
            .reduce(0, +)
    }

    private var thirtyDaySpend: Double {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return entries
            .filter { $0.timestamp >= cutoff }
            .map { $0.cost }
            .reduce(0, +)
    }
}
