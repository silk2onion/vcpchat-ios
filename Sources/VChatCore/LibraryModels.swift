import Foundation

public struct VCPAgent: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var systemPrompt: String
    public var model: String
    public var temperature: Double?
    public var createdAt: Double
    public var avatar: String
    public var avatarUrl: String
    public var description: String
    public var voice: String
    public var speechSpeed: Double
    public var speechDirector: String
    public init(id: String = UUID().uuidString, name: String = "新 Agent", systemPrompt: String = "", model: String = "", temperature: Double? = nil) {
        self.id = id; self.name = name; self.systemPrompt = systemPrompt; self.model = model
        self.temperature = temperature; createdAt = Date().timeIntervalSince1970
        avatar = ""; avatarUrl = ""; description = ""; voice = ""; speechSpeed = 1; speechDirector = ""
    }
}
public struct ChatTopic: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var ownerType: String
    public var ownerId: String
    public var title: String
    public var turnIndex: Int
    public var createdAt: Double
    public var updatedAt: Double
    public init(id: String = UUID().uuidString, ownerType: String = "agent", ownerId: String, title: String = "新对话") {
        self.id = id; self.ownerType = ownerType; self.ownerId = ownerId; self.title = title
        turnIndex = 0; createdAt = Date().timeIntervalSince1970; updatedAt = createdAt
    }
}
public struct UserProfile: Codable, Sendable, Equatable {
    public var name = ""
    public var avatar = ""
    public var mainAgentID = "assistant"
    public init() {}
}
