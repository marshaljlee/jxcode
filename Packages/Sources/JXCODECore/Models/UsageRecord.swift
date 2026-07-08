import Foundation

public struct UsageRecord: Codable, Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public let projectId: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cost: Double,
        projectId: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.projectId = projectId
    }
}
