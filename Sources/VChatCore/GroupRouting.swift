import Foundation

public enum GroupMode: String, Codable, CaseIterable, Sendable {
    case mention, rotate, all, random, inviteOnly = "invite_only"
    public var title: String {
        switch self {
        case .mention: "@点名，否则轮流"; case .rotate: "轮流一位"; case .all: "每位依次回复"
        case .random: "随机发言"; case .inviteOnly: "仅点名发言"
        }
    }
}
public struct VCPGroup: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var memberIds: [String]
    public var mode: GroupMode
    public var createdAt: Double
    public var systemPrompt: String
    public var unifiedModel: String
    public var avatarUrl: String
    public init(id: String = UUID().uuidString, name: String = "新群聊", memberIds: [String] = [], mode: GroupMode = .mention) {
        self.id = id; self.name = name; self.memberIds = memberIds; self.mode = mode
        createdAt = Date().timeIntervalSince1970; systemPrompt = ""; unifiedModel = ""; avatarUrl = ""
    }
}
public enum GroupRouting {
    public static func speakers(group: VCPGroup, agents: [VCPAgent], text: String, turn: Int) -> [VCPAgent] {
        let members = group.memberIds.compactMap { id in agents.first { $0.id == id } }
        guard !members.isEmpty else { return [] }
        let mentioned = members.sorted { $0.name.count > $1.name.count }.filter { agent in
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let regex = try? NSRegularExpression(pattern: "@" + NSRegularExpression.escapedPattern(for: name) + "(?=\\s|$|[，。,.!！?？])") else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if !mentioned.isEmpty { return mentioned }
        switch group.mode {
        case .all: return members
        case .inviteOnly: return []
        case .random: return members.randomElement().map { [$0] } ?? []
        case .rotate, .mention: return [members[Int(turn.magnitude % UInt(members.count))]]
        }
    }
}
public actor ConversationBuilder {
    public init() {}
    public func request(configuration: ConnectionConfiguration, apiKey: String, profile: UserProfile, agent: VCPAgent, group: VCPGroup?, messages: [StoredMessage], rules: [RegexRule] = [], output: OutputPreferences = .init(), location: LocationRequestContext? = nil) async throws -> ChatRequest {
        var config = configuration
        config.model = ModelResolution.resolve(global: configuration.model,agent: agent,group: group)
        guard !config.model.isEmpty else { throw ClientError.server("「\(agent.name)」还没有模型，请先设置默认模型") }
        var system: [String] = []
        if !profile.name.isEmpty { system.append("用户名叫「\(profile.name)」。") }
        if let group {
            if !group.systemPrompt.isEmpty { system.append(group.systemPrompt) }
            system.append("你正在群组「\(group.name)」里发言。你的名字是「\(agent.name)」。只以你自己的身份回复，不要代替其他成员说话。")
        }
        if !agent.systemPrompt.isEmpty { system.append(agent.systemPrompt) }
        if output.animatedBubbles { system.append("输出规范要求：{{VarDivRender}}") }
        if let location {
            system.append(location.policy)
            system.append(try location.tray())
        }
        var turns: [ChatTurn] = []
        if !system.isEmpty { turns.append(ChatTurn(role: "system", content: system.joined(separator: "\n\n"))) }
        let window = Array(messages.suffix(32)), depths = TurnDepths.calculate(Array(messages.suffix(32))), allRules = rules + agent.regexRules
        let lastUser = window.last(where: { $0.role == "user" })?.id
        for message in window where ["user", "assistant"].contains(message.role) {
            if let original = message.originalRole, !["user", "assistant"].contains(original) { continue }
            if message.role == "assistant" && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let transformed = try await RegexEngine.shared.apply(message.content, rules: allRules, scope: "context", role: message.role, depth: depths[message.id] ?? 0)
            let content = group != nil && message.role == "assistant" && !message.authorName.isEmpty ? "【\(message.authorName)】\n\(transformed)" : transformed
            turns.append(ChatTurn(role: message.role, content: content, attachments: message.role == "user" && message.id == lastUser ? message.attachments : []))
        }
        return ChatRequest(configuration: config, apiKey: apiKey, messages: turns, temperature: config.sendTemperature ? (agent.temperature ?? config.temperature) : nil)
    }
}
