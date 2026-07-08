import Foundation

public struct Agent: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var systemPrompt: String
    public var defaultTask: String?
    public var model: String
    public var enableFileRead: Bool
    public var enableFileWrite: Bool
    public var enableNetwork: Bool
    public var hooks: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        systemPrompt: String,
        defaultTask: String? = nil,
        model: String = "claude-sonnet-5-20251001",
        enableFileRead: Bool = true,
        enableFileWrite: Bool = true,
        enableNetwork: Bool = false,
        hooks: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.defaultTask = defaultTask
        self.model = model
        self.enableFileRead = enableFileRead
        self.enableFileWrite = enableFileWrite
        self.enableNetwork = enableNetwork
        self.hooks = hooks
        self.createdAt = createdAt
    }
}

public struct AgentRun: Codable, Identifiable, Hashable {
    public let id: UUID
    public let agentId: UUID
    public let agentName: String
    public let agentIcon: String
    public let task: String
    public let model: String
    public let projectPath: String
    public var status: String // "running", "completed", "failed", "cancelled"
    public var pid: Int32?
    public var startedAt: Date
    public var completedAt: Date?
    public var logFilePath: String

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        agentName: String,
        agentIcon: String,
        task: String,
        model: String,
        projectPath: String,
        status: String = "pending",
        pid: Int32? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        logFilePath: String
    ) {
        self.id = id
        self.agentId = agentId
        self.agentName = agentName
        self.agentIcon = agentIcon
        self.task = task
        self.model = model
        self.projectPath = projectPath
        self.status = status
        self.pid = pid
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.logFilePath = logFilePath
    }
}
