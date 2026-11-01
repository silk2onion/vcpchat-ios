import Foundation
import GRDB

public struct TopicToolPolicy: Codable, Sendable, Equatable {
    public var memo = false
    public var deepMemo = false
    public var sponsor = false
    public var readableAgents: Set<String> = []
    public var writableAgents: Set<String> = []
    public init() {}
    public var readers: Set<String> { readableAgents.union(writableAgents) }
}
public struct TopicToolState: Codable, Sendable, Equatable {
    public var locked = true
    public var unread = false
    public var creator = ""
    public init() {}
}
public struct TopicToolReply: Sendable {
    public var value: JSONValue
    public var changedTopicID: String?
}
private struct TopicToolReceipt: Codable {
    var arguments: JSONValue
    var agentID: String
    var value: JSONValue
    var topicID: String
}
public enum MobileTopicTool {
    public static let sponsorCommands = ["CreateTopic","ReadUnlockedTopics","CheckNewTopics","CheckUnreadMessages","ReplyToTopic","CheckTopicOwnership","ListUnlockedTopics","ReadTopicContent"]
    public static func manifests(deviceID: String, policy: TopicToolPolicy) throws -> [JSONValue] {
        let suffix = deviceID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !suffix.isEmpty, suffix.count <= 80 else { throw ClientError.server("设备标识无效") }
        func manifest(_ kind: String,_ commands: [String],_ description: String) -> JSONValue {
            .object(["name": .string("Mobile\(kind)_\(suffix)"),"displayName": .string(kind),"pluginType": .string("synchronous"),"version": .string("1.0.0"),"entryPoint": .object(["command": .string("native:topics")]),"communication": .object(["protocol": .string("direct"),"timeout": .number(120000)]),"description": .string(description),"capabilities": .object(["invocationCommands": .array(commands.map { .object(["command": .string($0),"commandIdentifier": .string($0),"description": .string(description)]) })])])
        }
        let common = "仅访问本机用户授权的Agent。maid用准确名字，重名时用agentId；topic_id必须来自本设备列表，不能混用Mac编号。offset/limit分页返回next_offset；读取正文时若next_content_offset非空，须同时携带next_offset与content_offset继续读取同条长消息。ReadUnlockedTopics的外层offset是话题偏移，history分页可用GetTopicContent继续读取。不修改或恢复历史。"
        var tools: [JSONValue] = []
        if policy.memo { tools.append(manifest("TopicMemo",["ListTopics","GetTopicContent"],common)) }
        if policy.deepMemo { tools.append(manifest("DeepMemo",["DeepMemo"],common + " keyword必需，支持短语、(关键词:权重)、[排除词]、{词1|词2:权重}；window_size为1–20，默认10。检索本机历史并返回前后上下文，不检索服务器日记。rerank:true需要用户配置精排服务。")) }
        if policy.sponsor { tools.append(manifest("TopicSponsor",sponsorCommands,common + " CreateTopic用topic_name、initial_message；ReplyToTopic用topic_id、message、sender_name；CheckNewTopics可用days；ReadUnlockedTopics可用include_read；CheckTopicOwnership用caller_name。写入需单独授权。锁定且已读的话题不可追加，生成或待发送中的话题不可追加。重复requestId不会重复写入。不提供心流自动生成。")) }
        return tools
    }
    public static func integer(_ value: JSONValue, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        if value == .null { return fallback }
        let number = value.number ?? Double(value.text)
        guard let number, number.isFinite, number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else { throw ClientError.server("分页或范围参数无效") }
        return Int(number)
    }
    public static func text(_ value: JSONValue, limit: Int = 200_000) throws -> String {
        guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= limit else { throw ClientError.server("缺少文字参数或内容过大") }
        return text
    }
    /// Extract readable content without evaluating HTML or loading remote resources.
    public static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>",with: "",options: .regularExpression)
            .replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li|/h[1-6])>",with: "\n",options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>",with: "",options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;",with: " ").replacingOccurrences(of: "&lt;",with: "<")
            .replacingOccurrences(of: "&gt;",with: ">").replacingOccurrences(of: "&quot;",with: "\"")
            .replacingOccurrences(of: "&#39;",with: "'").replacingOccurrences(of: "&amp;",with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatStore {
    private static func toolRecord<T: Decodable>(_ type: T.Type,_ db: Database,kind: String,id: String) throws -> T? {
        try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind=? AND id=?",arguments: [kind,id]).map { try JSONDecoder().decode(type,from: $0) }
    }
    private static func toolPut<T: Encodable>(_ value: T,_ db: Database,kind: String,id: String) throws {
        try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt",arguments: [kind,id,try JSONEncoder().encode(value),Date().timeIntervalSince1970])
    }
    public func topicToolStates() async throws -> [String:TopicToolState] {
        try await pool.read { db in
            var states = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db,sql: "SELECT id,payload FROM library WHERE kind='topic-tool-state'").map { row in
                let id: String = row["id"], data: Data = row["payload"]
                return (id,try JSONDecoder().decode(TopicToolState.self,from: data))
            })
            for data in try Data.fetchAll(db,sql: "SELECT payload FROM library WHERE kind='topic'") {
                let topic = try JSONDecoder().decode(ChatTopic.self,from: data)
                var state = states[topic.id] ?? TopicToolState()
                state.locked = topic.locked ?? state.locked; state.unread = topic.unread ?? state.unread; state.creator = topic.creator ?? state.creator
                states[topic.id] = state
            }
            return states
        }
    }
    public func updateTopicToolFlags(topicID: String,locked: Bool? = nil,markRead: Bool = false) async throws {
        try await pool.write { db in
            guard var topic = try Self.toolRecord(ChatTopic.self,db,kind: "topic",id: topicID) else { throw ClientError.server("话题已不存在") }
            var state = try Self.toolRecord(TopicToolState.self,db,kind: "topic-tool-state",id: topicID) ?? TopicToolState()
            state.locked = topic.locked ?? state.locked; state.unread = topic.unread ?? state.unread; state.creator = topic.creator ?? state.creator
            if let locked,locked != state.locked {
                try Self.toolPut(topic,db,kind: "topic-tool-backup",id: UUID().uuidString)
            }
            if let locked { state.locked = locked }
            if markRead { state.unread = false }
            topic.locked = state.locked; topic.unread = state.unread; topic.creator = state.creator
            try Self.toolPut(topic,db,kind: "topic",id: topicID)
            try Self.toolPut(state,db,kind: "topic-tool-state",id: topicID)
        }
    }
    public func topicAgent(_ args: JSONValue, policy: TopicToolPolicy, writing: Bool = false) async throws -> VCPAgent {
        let agents = try await records(VCPAgent.self,kind: "agent")
        let candidates = args["agentId"].text.isEmpty ? agents.filter { $0.name == args["maid"].text } : agents.filter { $0.id == args["agentId"].text }
        guard candidates.count == 1, let agent = candidates.first else { throw ClientError.server("Agent不存在或同名，请提供本设备agentId") }
        guard (writing ? policy.writableAgents : policy.readers).contains(agent.id) else { throw ClientError.server("用户未授权访问该Agent") }
        return agent
    }
    public func executeTopicTool(_ command: String, arguments args: JSONValue, requestID: String, policy: TopicToolPolicy) async throws -> TopicToolReply {
        let writing = ["CreateTopic","ReplyToTopic"].contains(command)
        let agent = try await topicAgent(args,policy: policy,writing: writing)
        let offset = try MobileTopicTool.integer(args["offset"],default: 0,range: 0...10_000_000)
        let limit = try MobileTopicTool.integer(args["limit"],default: 40,range: 1...100)
        return try await pool.write { db in
            guard try Self.toolRecord(VCPAgent.self,db,kind: "agent",id: agent.id) != nil else { throw ClientError.server("Agent已移除") }
            let topics = try Data.fetchAll(db,sql: "SELECT payload FROM library WHERE kind='topic'").map { try JSONDecoder().decode(ChatTopic.self,from: $0) }.filter { $0.ownerType == "agent" && $0.ownerId == agent.id }.sorted { $0.updatedAt > $1.updatedAt }
            func state(_ id: String) throws -> TopicToolState {
                var state = try Self.toolRecord(TopicToolState.self,db,kind: "topic-tool-state",id: id) ?? TopicToolState()
                if let topic = topics.first(where: { $0.id == id }) { state.locked = topic.locked ?? state.locked; state.unread = topic.unread ?? state.unread; state.creator = topic.creator ?? state.creator }
                return state
            }
            func rows(_ id: String) throws -> [StoredMessage] { try StoredMessage.fetchAll(db,sql: "SELECT * FROM messages WHERE topicID=? ORDER BY createdAt,rowid",arguments: [id]) }
            func metadata(_ topic: ChatTopic) throws -> JSONValue {
                let s = try state(topic.id)
                let count = try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM messages WHERE topicID=?",arguments: [topic.id]) ?? 0
                return .object(["id": .string(topic.id),"topic_id": .string(topic.id),"name": .string(topic.title),"topic_name": .string(topic.title),"createdAt": .number(topic.createdAt * 1000),"created_at": .number(topic.createdAt * 1000),"last_message_time": .number(topic.updatedAt * 1000),"message_count": .number(Double(count)),"locked": .bool(s.locked),"unread": .bool(s.unread),"agent_id": .string(agent.id)])
            }
            func page(_ messages: [StoredMessage]) throws -> JSONValue {
                let messageOffset = command == "ReadUnlockedTopics" ? 0 : offset
                let contentOffset = command == "ReadUnlockedTopics" ? 0 : try MobileTopicTool.integer(args["content_offset"],default: 0,range: 0...8_000_000)
                var used = 0, selected: [JSONValue] = []
                var next = messageOffset, nextContent: Int?
                for message in messages.dropFirst(messageOffset).prefix(limit) {
                    let body = MobileTopicTool.plain(message.content)
                    let start = selected.isEmpty ? contentOffset : 0
                    guard start <= body.unicodeScalars.count else { throw ClientError.server("正文偏移超过消息长度") }
                    let slice = String(body.unicodeScalars.dropFirst(start).prefix(40_000))
                    guard used + slice.utf8.count <= 240_000 else { break }
                    used += slice.utf8.count
                    selected.append(.object(["id": .string(message.id),"role": .string(message.role),"name": .string(message.authorName),"content": .string(slice),"content_offset": .number(Double(start)),"timestamp": .number(message.createdAt * 1000)]))
                    let end = start + slice.unicodeScalars.count
                    if end < body.unicodeScalars.count { nextContent = end; break }
                    next += 1
                }
                return .object(["messages": .array(selected),"total": .number(Double(messages.count)),"offset": .number(Double(messageOffset)),"next_offset": next < messages.count ? .number(Double(next)) : .null,"next_content_offset": nextContent.map { .number(Double($0)) } ?? .null])
            }
            if writing {
                guard !requestID.isEmpty, requestID.count <= 160 else { throw ClientError.server("缺少有效requestId") }
                if let receipt = try Self.toolRecord(TopicToolReceipt.self,db,kind: "topic-tool-receipt",id: requestID) {
                    guard receipt.arguments == args,receipt.agentID == agent.id else { throw ClientError.server("requestId已用于其他操作") }
                    guard topics.contains(where: { $0.id == receipt.topicID }) else { throw ClientError.server("此请求已处理，但话题已移除，不会恢复") }
                    return TopicToolReply(value: receipt.value,changedTopicID: receipt.topicID)
                }
                let body = try MobileTopicTool.text(args[command == "CreateTopic" ? "initial_message" : "message"])
                let now = Date().timeIntervalSince1970
                var topic: ChatTopic
                var s: TopicToolState
                let sender: String
                if command == "CreateTopic" {
                    topic = ChatTopic(ownerId: agent.id,title: try MobileTopicTool.text(args["topic_name"],limit: 500))
                    s = TopicToolState(); s.locked = false; s.creator = agent.name; sender = agent.name
                } else {
                    let topicID = args["topic_id"].text.isEmpty ? args["topicId"].text : args["topic_id"].text
                    guard let found = topics.first(where: { $0.id == topicID }) else { throw ClientError.server("话题不在该Agent范围内") }; topic = found; s = try state(topic.id)
                    guard !s.locked || s.unread else { throw ClientError.server("话题已锁定且已读，不能追加") }
                    guard try !Bool.fetchOne(db,sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE topicID=? AND status IN ('pending','connecting','streaming'))",arguments: [topic.id])! else { throw ClientError.server("话题正在生成或有待发送消息，请稍后再试") }
                    sender = try MobileTopicTool.text(args["sender_name"],limit: 200)
                    // Snapshot metadata before the append; old message rows are never overwritten.
                    try Self.toolPut(JSONValue.object(["topic": try JSONDecoder().decode(JSONValue.self,from: JSONEncoder().encode(topic)),"state": try JSONDecoder().decode(JSONValue.self,from: JSONEncoder().encode(s))]),db,kind: "topic-tool-backup",id: requestID)
                }
                try Task.checkCancellation()
                s.unread = true; topic.updatedAt = now
                topic.locked = s.locked; topic.unread = s.unread; topic.creator = s.creator
                let message = StoredMessage(topicID: topic.id,agentID: agent.id,authorName: sender,role: "assistant",content: body,createdAt: now)
                try Self.toolPut(topic,db,kind: "topic",id: topic.id); try Self.toolPut(s,db,kind: "topic-tool-state",id: topic.id); try message.insert(db)
                let value = JSONValue.object(["status": .string("success"),"topic_id": .string(topic.id),"topic_name": .string(topic.title),"agent_id": .string(agent.id),"message_id": .string(message.id),"unread": .bool(true)])
                try Self.toolPut(TopicToolReceipt(arguments: args,agentID: agent.id,value: value,topicID: topic.id),db,kind: "topic-tool-receipt",id: requestID)
                return TopicToolReply(value: value,changedTopicID: topic.id)
            }
            let value: JSONValue
            switch command {
            case "GetTopicContent","ReadTopicContent","CheckTopicOwnership":
                let topicID = args["topic_id"].text.isEmpty ? args["topicId"].text : args["topic_id"].text
                guard let topic = topics.first(where: { $0.id == topicID }) else { throw ClientError.server("话题不在该Agent范围内") }
                if command == "CheckTopicOwnership" {
                    let creator = try state(topic.id).creator, caller = try MobileTopicTool.text(args["caller_name"],limit: 200)
                    value = .object(["is_owner": .bool(!creator.isEmpty && creator == caller),"creator_name": .string(creator.isEmpty ? "unknown" : creator),"topic_name": .string(topic.title)])
                } else {
                    var info = try metadata(topic).object
                    let history = try page(rows(topic.id)); info["history"] = history
                    info["messages"] = history["messages"]; info["next_offset"] = history["next_offset"]; info["next_content_offset"] = history["next_content_offset"]
                    if command == "ReadTopicContent" {
                        let format = args["format"].text.lowercased()
                        guard ["","markdown","md","json","raw"].contains(format) else { throw ClientError.server("format应为markdown或json；raw仍仅返回本机正文，不包含附件原件") }
                        if ["","markdown","md"].contains(format) {
                            info["content"] = .string("# \(topic.title)\n\n" + history["messages"].array.map { "**\($0["name"].text)**\n\n\($0["content"].text)" }.joined(separator: "\n\n---\n\n"))
                        }
                    }
                    value = .object(info)
                }
            case "ListTopics","ListUnlockedTopics","ReadUnlockedTopics","CheckNewTopics","CheckUnreadMessages":
                let days = try MobileTopicTool.integer(args["days"],default: 3,range: 1...3650)
                let includeRead = args["include_read"].bool == true || args["include_read"].text.lowercased() == "true"
                let filtered = try topics.filter { topic in
                    let s = try state(topic.id)
                    switch command {
                    case "ListUnlockedTopics": return !s.locked
                    case "ReadUnlockedTopics": return !s.locked && (includeRead || s.unread)
                    case "CheckNewTopics": return !s.locked && topic.createdAt > Date().timeIntervalSince1970 - Double(days) * 86400
                    case "CheckUnreadMessages": return s.unread
                    default: return true
                    }
                }
                var list: [JSONValue] = [], bytes = 0
                for topic in filtered.dropFirst(offset).prefix(command == "ReadUnlockedTopics" ? min(limit,5) : limit) {
                    var info = try metadata(topic).object
                    if command == "ReadUnlockedTopics" { info["history"] = try page(rows(topic.id)) }
                    let row = JSONValue.object(info); let size = try JSONEncoder().encode(row).count
                    guard bytes + size <= 300_000 else { break }; bytes += size; list.append(row)
                }
                let next = offset + list.count
                var info: [String:JSONValue] = ["agent_id": .string(agent.id),"agent_name": .string(agent.name),"topics": .array(list),"total": .number(Double(filtered.count)),"total_topics": .number(Double(filtered.count)),"next_offset": next < filtered.count ? .number(Double(next)) : .null]
                if command == "CheckUnreadMessages" { info["has_unread"] = .bool(!filtered.isEmpty); info["unread_topics"] = .array(list) }
                if command == "CheckNewTopics" { info["has_new_topics"] = .bool(!filtered.isEmpty); info["new_topics_count"] = .number(Double(filtered.count)) }
                if command == "ListUnlockedTopics" { info["has_unlocked_topics"] = .bool(!filtered.isEmpty); info["unlocked_topics_count"] = .number(Double(filtered.count)) }
                value = .object(info)
            default: throw ClientError.server("不支持的移动话题指令")
            }
            return TopicToolReply(value: value,changedTopicID: nil)
        }
    }
}
