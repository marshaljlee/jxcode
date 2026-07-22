import Foundation

// MARK: - Routing App
// From JXRouter — per-app routing assignment.

public struct RoutingApp: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let bundleIdentifier: String
    public let icon: String  // SF Symbol name
    public let detectedAt: Date
    public var status: RoutingStatus
    public var routeAssignment: RouteAssignment
    public var lastSeen: Date
    public var connectionCount: Int
    public var processIds: [Int]

    public enum RoutingStatus: Equatable {
        case routed
        case detected
        case ignored
        case blocked
        case unknown

        public var label: String {
            switch self {
            case .routed: return "Routed"
            case .detected: return "Detected"
            case .ignored: return "Ignored"
            case .blocked: return "Blocked"
            case .unknown: return "Unknown"
            }
        }
    }

    public enum RouteAssignment: String, Codable, CaseIterable, Identifiable {
        case auto = "Auto"
        case direct = "Direct"
        case openrouter = "OpenRouter"
        case opencode = "OpenCode"
        case openai = "OpenAI"
        case local = "Local"
        case block = "Block"

        public var id: String { rawValue }
    }

    public init(id: UUID, name: String, bundleIdentifier: String, icon: String, detectedAt: Date, status: RoutingStatus, routeAssignment: RouteAssignment, lastSeen: Date, connectionCount: Int, processIds: [Int]) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.detectedAt = detectedAt
        self.status = status
        self.routeAssignment = routeAssignment
        self.lastSeen = lastSeen
        self.connectionCount = connectionCount
        self.processIds = processIds
    }

    static let examples: [RoutingApp] = [
        RoutingApp(
            id: UUID(),
            name: "Claude CLI",
            bundleIdentifier: "com.anthropic.claude",
            icon: "terminal.fill",
            detectedAt: Date().addingTimeInterval(-86400),
            status: .routed,
            routeAssignment: .direct,
            lastSeen: Date().addingTimeInterval(-300),
            connectionCount: 247,
            processIds: [98432, 98433]
        ),
        RoutingApp(
            id: UUID(),
            name: "JXCODE",
            bundleIdentifier: "com.idealapp.JXCODE",
            icon: "hammer.fill",
            detectedAt: Date().addingTimeInterval(-43200),
            status: .routed,
            routeAssignment: .direct,
            lastSeen: Date().addingTimeInterval(-600),
            connectionCount: 89,
            processIds: [97651]
        ),
        RoutingApp(
            id: UUID(),
            name: "Cursor",
            bundleIdentifier: "com.todesktop.23011353",
            icon: "cursorarrow.square",
            detectedAt: Date().addingTimeInterval(-7200),
            status: .detected,
            routeAssignment: .auto,
            lastSeen: Date().addingTimeInterval(-3600),
            connectionCount: 12,
            processIds: [88123]
        ),
    ]
}
