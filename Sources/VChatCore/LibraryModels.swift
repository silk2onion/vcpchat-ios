import Foundation

public struct VCPAgent: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var systemPrompt: String
    public var model: String
    public var temperature: Double?
    public var contextTokenLimit: Int?
    public var maxOutputTokens: Int?
    public var createdAt: Double
    public var avatar: String
    public var avatarUrl: String
    public var description: String
    public var voice: String
    public var speechSpeed: Double
    public var speechSpeedInherited: Bool
    public var speechDirector: String
    public var regexRules: [RegexRule]
    public init(id: String = UUID().uuidString, name: String = "新 Agent", systemPrompt: String = "", model: String = "", temperature: Double? = nil) {
        self.id = id; self.name = name; self.systemPrompt = systemPrompt; self.model = model
        self.temperature = temperature; createdAt = Date().timeIntervalSince1970
        avatar = ""; avatarUrl = ""; description = ""; voice = ""; speechSpeed = 1; speechSpeedInherited = true; speechDirector = ""; regexRules = []
    }
    enum CodingKeys: String, CodingKey { case id, name, systemPrompt, model, temperature, contextTokenLimit, maxOutputTokens, createdAt, avatar, avatarUrl, description, voice, speechSpeed, speechSpeedInherited, speechDirector, regexRules }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), systemPrompt: try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "", model: try c.decodeIfPresent(String.self, forKey: .model) ?? "", temperature: try c.decodeIfPresent(Double.self, forKey: .temperature))
        contextTokenLimit = try c.decodeIfPresent(Int.self, forKey: .contextTokenLimit)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? createdAt
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        speechSpeed = try c.decodeIfPresent(Double.self, forKey: .speechSpeed) ?? 1
        speechSpeedInherited = try c.decodeIfPresent(Bool.self, forKey: .speechSpeedInherited) ?? true
        speechDirector = try c.decodeIfPresent(String.self, forKey: .speechDirector) ?? ""
        regexRules = try c.decodeIfPresent([RegexRule].self, forKey: .regexRules) ?? []
    }

}
public struct ChatTopic: Codable, Sendable, Identifiable, Equatable {
    public var locked: Bool? = nil
    public var unread: Bool? = nil
    public var creator: String? = nil
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
