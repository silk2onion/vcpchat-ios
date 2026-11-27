import Foundation

public enum ReplyInjectionPosition: String, Codable, CaseIterable, Sendable {
    case systemSuffix = "system_suffix"
    case userSuffix = "user_suffix"
    case context = "context_inject"
    public var title: String {
        switch self {
        case .systemSuffix: "系统提示词尾部"
        case .userSuffix: "本轮用户消息尾部"
        case .context: "按深度插入上下文"
        }
    }
}
public enum ReplyRuleScope: String, Codable, CaseIterable, Sendable {
    case global, agent, group
    public var title: String {
        switch self {
        case .global: "单聊和群聊"
        case .agent: "仅单聊"
        case .group: "仅群聊"
        }
    }
}
public enum ReplyInjectionRole: String, Codable, CaseIterable, Sendable {
    case user, assistant
    public var title: String { self == .user ? "用户" : "助手" }
}
public struct ReplyRuleOwner: Hashable, Sendable {
    public enum Kind: String, Sendable { case agent, group }
    public let kind: Kind
    public let id: String
    public init(_ kind: Kind,id: String) { self.kind = kind; self.id = id }
    fileprivate var key: String { "\(kind.rawValue):\(id)" }
}

public struct AdvancedReplyRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var type: ReplyInjectionPosition
    public var enabled: Bool
    public var content: String
    public var scope: ReplyRuleScope
    public var wrap: Bool
    public var builtinKey: String?
    public var role: ReplyInjectionRole?
    public var depth: Int?
    public var isBuiltin: Bool { builtinKey != nil }

    public init(id: String = UUID().uuidString,name: String = "",type: ReplyInjectionPosition = .systemSuffix,
                enabled: Bool = true,content: String = "",scope: ReplyRuleScope = .global,wrap: Bool = true,
                builtinKey: String? = nil,role: ReplyInjectionRole? = nil,depth: Int? = nil) {
        self.id = id; self.name = name; self.type = type; self.enabled = enabled
        self.content = content; self.scope = scope; self.wrap = wrap; self.builtinKey = builtinKey
        self.role = role; self.depth = depth
    }
    public func applies(to owner: ReplyRuleOwner) -> Bool { scope == .global || scope.rawValue == owner.kind.rawValue }
    fileprivate var requestText: String {
        wrap ? "[本信息由VCPChat客户端注入]\n\(content)\n[临时注入结束]" : content
    }
}

/// Local request settings. Neither rules nor owner overrides are part of chat history or the desktop sync DTO.
public struct AdvancedReplyConfiguration: Codable, Sendable, Equatable {
    private static let bubbleID = "builtin_agent_div_render"
    public var rules: [AdvancedReplyRule]
    private var overrides: [String:[String:Bool]]

    public init(rules: [AdvancedReplyRule] = []) { self.rules = rules; overrides = [:] }

    public static func seeded(legacy: OutputPreferences) throws -> Self {
        struct Presets: Decodable { let version: Int; let rules: [AdvancedReplyRule] }
        guard let url = Bundle.module.url(forResource: "AdvancedReplies.official",withExtension: "json") else {
            throw ClientError.server("找不到高级回复预置")
        }
        let presets = try JSONDecoder().decode(Presets.self,from: Data(contentsOf: url))
        guard presets.version == 3,Set(presets.rules.map(\.id)).count == presets.rules.count,
              let bubble = presets.rules.firstIndex(where: { $0.id == bubbleID }) else {
            throw ClientError.server("高级回复预置格式无效")
        }
        var result = Self(rules: presets.rules)
        if legacy.animatedBubbles {
            result.rules[bubble].enabled = true
            // Preserve the exact text sent by installations already using the old switch.
            result.rules[bubble].wrap = false
        }
        return result
    }

    public var animatedBubbles: Bool {
        get { rules.first { $0.id == Self.bubbleID }?.enabled ?? false }
        set {
            if let index = rules.firstIndex(where: { $0.id == Self.bubbleID }) { rules[index].enabled = newValue }
        }
    }
    public func override(for id: String,owner: ReplyRuleOwner) -> Bool? { overrides[owner.key]?[id] }
    public func overrideCount(for owner: ReplyRuleOwner) -> Int {
        rules.filter { $0.applies(to: owner) && override(for: $0.id,owner: owner) != nil }.count
    }
    public mutating func setOverride(_ value: Bool?,for id: String,owner: ReplyRuleOwner) {
        guard rules.contains(where: { $0.id == id && $0.applies(to: owner) }) else { return }
        if let value { overrides[owner.key,default: [:]][id] = value }
        else {
            overrides[owner.key]?.removeValue(forKey: id)
            if overrides[owner.key]?.isEmpty == true { overrides.removeValue(forKey: owner.key) }
        }
    }
    public mutating func removeRule(id: String) {
        rules.removeAll { $0.id == id && !$0.isBuiltin }
        if !rules.contains(where: { $0.id == id }) {
            for key in Array(overrides.keys) {
                overrides[key]?.removeValue(forKey: id)
                if overrides[key]?.isEmpty == true { overrides.removeValue(forKey: key) }
            }
        }
    }

    func plan(for owner: ReplyRuleOwner) -> ReplyInjectionPlan {
        let active = rules.filter { $0.applies(to: owner) &&
            (override(for: $0.id,owner: owner) ?? $0.enabled) &&
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ReplyInjectionPlan(rules: active)
    }
}

struct ReplyInjectionPlan {
    let system: [String]
    let user: [String]
    private let context: [AdvancedReplyRule]
    init(rules: [AdvancedReplyRule] = []) {
        system = rules.filter { $0.type == .systemSuffix }.map(\.requestText)
        user = rules.filter { $0.type == .userSuffix }.map(\.requestText)
        context = rules.enumerated().filter { $0.element.type == .context }.sorted { a,b in
            let left = max(0,a.element.depth ?? 0), right = max(0,b.element.depth ?? 0)
            return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
    }
    func appendingToUser(_ text: String) -> String {
        guard !user.isEmpty else { return text }
        return ([text].filter { !$0.isEmpty } + user).joined(separator: "\n\n")
    }
    func insertContext(into turns: inout [ChatTurn]) {
        var groups = turns.map { [$0] }
        insertContext(into: &groups); turns = groups.flatMap { $0 }
    }
    func insertContext(into turns: inout [[ChatTurn]]) {
        guard !context.isEmpty else { return }
        let firstConversation = turns.first?.first?.role == "system" ? 1 : 0
        var result: [[ChatTurn]] = []
        result.reserveCapacity(turns.count + context.count)
        var start = 0
        for rule in context {
            let position = max(firstConversation,turns.count - max(0,rule.depth ?? 0))
            result.append(contentsOf: turns[start..<position])
            result.append([ChatTurn(role: (rule.role ?? .user).rawValue,content: rule.requestText)])
            start = position
        }
        result.append(contentsOf: turns[start...])
        turns = result
    }
}
