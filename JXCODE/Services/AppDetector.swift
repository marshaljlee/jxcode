import Foundation
import OSLog
import Observation

// MARK: - App Detector
// JXRouter's improved detection merged with jxcode's @Observable for SwiftUI.

@MainActor
@Observable
public final class AppDetector {
    public static let shared = AppDetector()
    private let log = Logger(subsystem: "com.jxcode", category: "detector")

    public private(set) var detectedApps: [RoutingApp] = []
    private var monitoringTask: Task<Void, Never>?

    private static let knownClients: [(name: String, bundleId: String, icon: String)] = [
        ("Claude CLI", "com.anthropic.claude", "terminal.fill"),
        ("Claude Desktop", "com.anthropic.claude-desktop", "bubble.left.fill"),
        ("JXCODE", "com.idealapp.JXCODE", "hammer.fill"),
        ("Cursor", "com.todesktop.23011353", "cursorarrow.square"),
        ("Windsurf", "com.codeium.windsurf", "wind.snow"),
        ("Continue", "com.continue.dev", "arrowtriangle.right.fill"),
        ("GitHub Copilot", "com.github.copilot", "chevron.left.forwardslash.chevron.right"),
    ]

    public func startMonitoring(port: Int = 5255) {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.scan(port: port)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self.scan(port: port)
            }
        }
    }

    public func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    public func setRoute(appId: UUID, assignment: RoutingApp.RouteAssignment) {
        if let idx = detectedApps.firstIndex(where: { $0.id == appId }) {
            var app = detectedApps[idx]
            app.routeAssignment = assignment
            app.status = assignment == .block ? .blocked : .routed
            detectedApps[idx] = app
        }
    }

    public func ignoreApp(appId: UUID) {
        if let idx = detectedApps.firstIndex(where: { $0.id == appId }) {
            detectedApps[idx].status = .ignored
        }
    }

    // MARK: - Scanning

    private func scan(port: Int) async {
        let processes = findProcesses(on: port)
        var updated: [RoutingApp] = []

        for (pid, name) in processes {
            if let idx = updated.firstIndex(where: { $0.processIds.contains(pid) }) {
                updated[idx].connectionCount += 1
                updated[idx].lastSeen = Date()
            } else {
                let known = Self.knownClients.first { name.localizedCaseInsensitiveContains($0.name) || name.localizedCaseInsensitiveContains($0.bundleId) }
                let app = RoutingApp(
                    id: UUID(),
                    name: known?.name ?? name,
                    bundleIdentifier: known?.bundleId ?? "unknown.\(name.lowercased())",
                    icon: known?.icon ?? "questionmark.square.dashed",
                    detectedAt: Date(),
                    status: .detected,
                    routeAssignment: .auto,
                    lastSeen: Date(),
                    connectionCount: 1,
                    processIds: [pid]
                )
                updated.append(app)
            }
        }

        // Merge with existing (preserve user routing assignments)
        for i in updated.indices {
            if let existing = detectedApps.first(where: { $0.bundleIdentifier == updated[i].bundleIdentifier }) {
                updated[i].routeAssignment = existing.routeAssignment
                updated[i].status = existing.status == .routed ? .routed : updated[i].status
            }
        }

        detectedApps = updated
    }

    private func findProcesses(on port: Int) -> [(pid: Int, name: String)] {
        let cmd = "lsof -ti :\(port) 2>/dev/null | head -30"
        guard let output = try? shell(cmd) else { return [] }
        let pids = output.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }

        return pids.compactMap { pid in
            guard let name = try? shell("ps -p \(pid) -o comm= 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return (pid, name)
        }
    }

    private func shell(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
