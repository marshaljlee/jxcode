import Foundation

// MARK: - Proxy Status
// From JXRouter — extended status model.

public enum ProxyStatus: Equatable {
    case stopped
    case starting(progress: Double)
    case running(pid: Int, uptime: TimeInterval, port: Int)
    case stopping
    case failed(error: String)

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .failed: return "Error"
        }
    }

    public var isActive: Bool {
        if case .running = self { return true }
        if case .starting = self { return true }
        return false
    }

    public var isTerminal: Bool {
        if case .stopped = self { return true }
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Proxy Stats

public struct ProxyStats: Equatable {
    public var requestsTotal: Int = 0
    public var successfulRequests: Int = 0
    public var failedRequests: Int = 0
    public var activeProviders: Int = 0
    public var uptimeSeconds: TimeInterval = 0
    public var bytesTransferred: Int64 = 0
    public var currentUpstreamLatency: TimeInterval? = nil
    public var startTime: Date? = nil

    public init() {}
}

// MARK: - Proxy Log Entry

public struct ProxyLogEntry: Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: ProxyConfig.LogLevel
    public let message: String
    public let source: String

    public init(id: UUID, timestamp: Date, level: ProxyConfig.LogLevel, message: String, source: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.source = source
    }
}
