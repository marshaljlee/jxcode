import SwiftUI
import Charts
import JXCODECore

struct UsageDashboardView: View {
    @State private var entries: [UsageService.UsageEntry] = []
    @State private var selectedPeriod = 7 // 7, 30 days
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage Analytics")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text("Token utilization and cost metrics aggregated from local session logs")
                        .font(.subheadline)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                
                Spacer()
                
                Picker("Period", selection: $selectedPeriod) {
                    Text("Last 7 Days").tag(7)
                    Text("Last 30 Days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(20)
            .background(ClaudeTheme.surfaceElevated)

            ClaudeThemeDivider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState
            } else {
                dashboardContent
            }
        }
        .background(ClaudeTheme.background)
        .task {
            entries = await UsageService.shared.loadAllUsage()
            isLoading = false
        }
        .onChange(of: selectedPeriod) { _, _ in
            // Re-fetch or refresh views
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar")
                .font(.system(size: ClaudeTheme.size(48)))
                .foregroundStyle(ClaudeTheme.textTertiary)

            Text("No usage records found")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            Text("Run interactive prompts or background agents to generate token logs.")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Key Metrics Row
                HStack(spacing: 16) {
                    metricCard(title: "Total Spent", value: String(format: "$%.3f", totalSpent), subtitle: "For selected period")
                    metricCard(title: "Input Tokens", value: formatNumber(totalInputTokens), subtitle: "Sent prompts")
                    metricCard(title: "Output Tokens", value: formatNumber(totalOutputTokens), subtitle: "Claude completions")
                    metricCard(title: "Cached Hits", value: String(format: "%.1f%%", cacheHitRate * 100), subtitle: "Token cache creation & read")
                }

                // Daily Cost Chart
                VStack(alignment: .leading, spacing: 12) {
                    Text("Daily Cost Trend ($)")
                        .font(.headline)
                        .foregroundStyle(ClaudeTheme.textPrimary)

                    Chart(dailyCosts) { item in
                        BarMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Cost", item.cost)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [ClaudeTheme.accent, ClaudeTheme.accent.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                    }
                    .frame(height: 200)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.month().day())
                        }
                    }
                }
                .padding(16)
                .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

                // Breakdown side-by-side
                HStack(alignment: .top, spacing: 16) {
                    // Model Breakdown (Pie Chart)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cost by Model")
                            .font(.headline)
                            .foregroundStyle(ClaudeTheme.textPrimary)

                        if modelCosts.isEmpty {
                            Text("No model breakdown data")
                                .font(.subheadline)
                                .foregroundStyle(ClaudeTheme.textSecondary)
                        } else {
                            Chart(modelCosts) { item in
                                SectorMark(
                                    angle: .value("Cost", item.cost),
                                    innerRadius: .ratio(0.6),
                                    angularInset: 1.5
                                )
                                .cornerRadius(4)
                                .foregroundStyle(by: .value("Model", item.model))
                            }
                            .frame(height: 200)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

                    // Project Breakdown (Horizontal Bar Chart)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Top Projects by Spend")
                            .font(.headline)
                            .foregroundStyle(ClaudeTheme.textPrimary)

                        if projectCosts.isEmpty {
                            Text("No project breakdown data")
                                .font(.subheadline)
                                .foregroundStyle(ClaudeTheme.textSecondary)
                        } else {
                            Chart(projectCosts) { item in
                                BarMark(
                                    x: .value("Cost", item.cost),
                                    y: .value("Project", item.projectName)
                                )
                                .foregroundStyle(ClaudeTheme.accent)
                                .cornerRadius(3)
                            }
                            .frame(height: 200)
                            .chartYAxis {
                                AxisMarks { value in
                                    AxisValueLabel()
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
            
            Text(value)
                .font(.title.weight(.bold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            
            Text(subtitle)
                .font(.system(size: ClaudeTheme.size(9)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Filtered Calculations

    private var filteredEntries: [UsageService.UsageEntry] {
        let cutoff = Date().addingTimeInterval(-Double(selectedPeriod) * 24 * 3600)
        return entries.filter { $0.timestamp >= cutoff }
    }

    private var totalSpent: Double {
        filteredEntries.map { $0.cost }.reduce(0, +)
    }

    private var totalInputTokens: Int {
        filteredEntries.map { $0.inputTokens }.reduce(0, +)
    }

    private var totalOutputTokens: Int {
        filteredEntries.map { $0.outputTokens }.reduce(0, +)
    }

    private var cacheHitRate: Double {
        let read = filteredEntries.map { $0.cacheReadTokens }.reduce(0, +)
        let total = filteredEntries.map { $0.inputTokens }.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(read) / Double(total)
    }

    private var dailyCosts: [DailyCost] {
        let calendar = Calendar.current
        var dailyMap: [Date: Double] = [:]
        
        // Seed map for dates in range
        let today = Date()
        for i in 0..<selectedPeriod {
            if let date = calendar.date(byAdding: .day, value: -i, to: today),
               let normalized = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: date) {
                dailyMap[normalized] = 0.0
            }
        }

        for entry in filteredEntries {
            if let normalized = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: entry.timestamp) {
                // Find matching key in the last N days
                if let key = dailyMap.keys.first(where: { calendar.isDate($0, inSameDayAs: normalized) }) {
                    dailyMap[key, default: 0.0] += entry.cost
                }
            }
        }

        return dailyMap.map { DailyCost(date: $0.key, cost: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private var modelCosts: [ModelCost] {
        var map: [String: Double] = [:]
        for entry in filteredEntries {
            let modelName: String
            if entry.model.contains("sonnet") {
                modelName = "3.5 Sonnet"
            } else if entry.model.contains("haiku") {
                modelName = "3.5 Haiku"
            } else if entry.model.contains("opus") {
                modelName = "3.0 Opus"
            } else {
                modelName = entry.model
            }
            map[modelName, default: 0.0] += entry.cost
        }
        return map.map { ModelCost(model: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    private var projectCosts: [ProjectCost] {
        var map: [String: Double] = [:]
        for entry in filteredEntries {
            let url = URL(fileURLWithPath: entry.projectPath)
            let name = url.lastPathComponent.isEmpty ? entry.projectPath : url.lastPathComponent
            map[name, default: 0.0] += entry.cost
        }
        // Limit to top 5
        let sorted = map.map { ProjectCost(projectName: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        return Array(sorted.prefix(5))
    }

    // MARK: - Formatters

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }

    // Helper structs
    struct DailyCost: Identifiable {
        let id = UUID()
        let date: Date
        let cost: Double
    }

    struct ModelCost: Identifiable {
        let id = UUID()
        let model: String
        let cost: Double
    }

    struct ProjectCost: Identifiable {
        let id = UUID()
        let projectName: String
        let cost: Double
    }
}
