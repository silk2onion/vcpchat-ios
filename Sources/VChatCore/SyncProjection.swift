import Foundation
public struct SyncSnapshot: Codable, Sendable, Equatable {
    public var agents: [VCPAgent] = []; public var groups: [VCPGroup] = []; public var topics: [ChatTopic] = []; public var messages: [StoredMessage] = []
    public init() {}
    public func managed(by profile: SyncProfile) -> Self {
        var out = Self(); let prefix = "sync:\(profile.id):"
        out.agents = agents.filter { $0.id.hasPrefix(prefix) }; out.groups = groups.filter { $0.id.hasPrefix(prefix) }
        out.topics = topics.filter { $0.ownerId.hasPrefix(prefix) }
        let topics = Set(out.topics.map(\.id)); out.messages = messages.filter { topics.contains($0.topicID) }; return out
    }
    public func ordered() -> Self { var v = self; v.agents.sort { $0.id < $1.id }; v.groups.sort { $0.id < $1.id }; v.topics.sort { $0.id < $1.id }; v.messages.sort { $0.id < $1.id }; return v }
}
public struct SyncEntity: Codable, Sendable, Equatable {
    public var identity: SyncIdentity; public var localId: String?; public var data: JSONValue
    public var configHash: String; public var contentHash = ""; public var updatedAt: Double; public var deletedAt: Double?
    public init(identity: SyncIdentity,data: JSONValue,updatedAt: Double) { self.identity = identity; self.data = data; self.updatedAt = updatedAt; configHash = SyncWire.dtoHash(data,identity: identity) }
    public var manifest: JSONValue { var v = identity.json; v.removeValue(forKey: "entityType"); if let deletedAt { v["deletedAt"] = .number(deletedAt) } else { v["configHash"] = .string(configHash); v["updatedAt"] = .number(updatedAt); if identity.entityType == "owner" { v["contentHash"] = .string(contentHash) } }; return .object(v) }
}
public struct SyncProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String; public var endpoint: String
    public var entities: [String:SyncEntity] = [:]; public var messages: [String:[JSONValue]] = [:]; public var avatars: [String:JSONValue] = [:]
    public var messageDeletes: [String:[String:Double]] = [:]; public var lastSync: Double = 0
    public init(id: String = UUID().uuidString,endpoint: String) { self.id = id; self.endpoint = endpoint }
    public func localID(_ kind: String,_ id: String,owner: String = "") -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return "sync:\(self.id):\(kind):\(owner.addingPercentEncoding(withAllowedCharacters: allowed)!):\(id.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }
    public func entityID(_ e: SyncEntity) -> String { e.localId ?? localID(e.identity.entityType == "owner" ? e.identity.ownerType : "topic",e.identity.topicId ?? e.identity.ownerId,owner: e.identity.entityType == "topic" ? "\(e.identity.ownerType):\(e.identity.ownerId)" : "") }
    public func toLocal(extras: SyncSnapshot = SyncSnapshot()) -> SyncSnapshot {
        var out = SyncSnapshot(), agents: [String:String] = [:]
        let oldMessages = Dictionary(uniqueKeysWithValues: extras.messages.map { ($0.id,$0) })
        for e in entities.values where e.identity.entityType == "owner" && e.identity.ownerType == "agent" && e.deletedAt == nil { agents[e.identity.ownerId] = entityID(e) }
        for e in entities.values.sorted(by: { $0.identity.key < $1.identity.key }) where e.deletedAt == nil {
            let identity = e.identity, d = e.data, id = entityID(e), avatar = avatars[identity.ownerType + "\0" + identity.ownerId]
            if identity.entityType == "owner" && identity.ownerType == "agent" {
                var a = extras.agents.first { $0.id == id } ?? VCPAgent(id: id)
                a.name = d["name"].text.isEmpty ? "未命名 Agent" : d["name"].text; a.systemPrompt = d["systemPrompt"].text; a.model = d["model"].text; a.temperature = d["temperature"].number
                a.createdAt = ((try? SyncWire.time(d["createdAt"])) ?? e.updatedAt)/1000; if let avatar { a.avatarUrl = avatar["image"].text }; out.agents.append(a)
            } else if identity.entityType == "owner" {
                var g = extras.groups.first { $0.id == id } ?? VCPGroup(id: id)
                g.name = d["name"].text.isEmpty ? "未命名群组" : d["name"].text; g.memberIds = d["members"].array.compactMap { agents[$0.text] }
                g.mode = d["mode"].text == "sequential" ? .all : d["mode"].text == "random" ? .random : .inviteOnly
                g.systemPrompt = d["groupPrompt"].text; g.unifiedModel = d["useUnifiedModel"].bool == true ? d["unifiedModel"].text : ""
                g.createdAt = ((try? SyncWire.time(d["createdAt"])) ?? e.updatedAt)/1000; if let avatar { g.avatarUrl = avatar["image"].text }; out.groups.append(g)
            } else {
                guard let owner = entities[identity.owner.key],owner.deletedAt == nil else { continue }
                let rows = messages[identity.topicKey] ?? []; var t = ChatTopic(id: id,ownerType: identity.ownerType,ownerId: entityID(owner),title: d["name"].text.isEmpty ? "同步会话" : d["name"].text)
                t.createdAt = ((try? SyncWire.time(d["createdAt"])) ?? e.updatedAt)/1000; t.updatedAt = max(e.updatedAt,rows.map { $0["timestamp"].number ?? 0 }.max() ?? 0)/1000; out.topics.append(t)
                for m in rows {
                    let mid = m["localId"].text.isEmpty ? localID("message",m["id"].text,owner: identity.topicKey) : m["localId"].text
                    let old = oldMessages[mid],role = m["role"].text
                    var body = m["content"].text,reasoning = old?.reasoning ?? ""
                    if role == "assistant",body.hasPrefix("<think>"),let closing = body.range(of: "</think>") {
                        reasoning = String(body[body.index(body.startIndex,offsetBy: 7)..<closing.lowerBound])
                        body = String(body[closing.upperBound...]); if body.hasPrefix("\n") { body.removeFirst() }
                    }
                    let attachments: [ChatAttachment] = m["attachments"].array.map { a in
                        if let kept = old?.attachments.first(where: { $0.hash == a["hash"].text && $0.desktopOnly != true }) { return kept }
                        return ChatAttachment(id: a["hash"].text,name: a["name"].text,mime: a["type"].text,kind: a["type"].text.hasPrefix("image/") ? "image" : "text",text: a["extractedText"].text.isEmpty ? nil : a["extractedText"].text,hash: a["hash"].text,desktopOnly: true)
                    }
                    out.messages.append(StoredMessage(id: mid,topicID: id,agentID: agents[m["agentId"].text] ?? "",authorName: m["name"].text,role: role == "user" ? "user" : "assistant",content: body,reasoning: reasoning,status: old?.content == body ? old!.status : "complete",createdAt: (m["timestamp"].number ?? 0)/1000,attachments: attachments,originalRole: ["user","assistant"].contains(role) ? nil : role,syncNotice: ["user","assistant"].contains(role) ? nil : "原消息类型：\(role)"))
                }
            }
        }; return out
    }
    public mutating func refreshRoots() {
        for (key,var e) in entities where e.identity.entityType == "topic" && e.deletedAt == nil {
            e.contentHash = SyncWire.aggregate((messages[e.identity.topicKey] ?? []).map { SyncWire.hash(.object(["id":$0["id"],"hash":$0["contentHash"]])) }); entities[key] = e
        }
        for (key,var e) in entities where e.identity.entityType == "owner" && e.deletedAt == nil {
            e.contentHash = SyncWire.aggregate(entities.values.filter { $0.identity.entityType == "topic" && $0.identity.owner == e.identity && $0.deletedAt == nil }.map { SyncWire.hash(.object(["topicId":.string($0.identity.topicId!),"configHash":.string($0.configHash),"contentHash":.string($0.contentHash)])) }); entities[key] = e
        }
    }
    public mutating func overlay(_ local: SyncSnapshot,versions: [String:Double] = [:],now: Double = SyncWire.now) throws {
        let baseline = toLocal(), owners = Dictionary(uniqueKeysWithValues: entities.values.filter { $0.identity.entityType == "owner" }.map { (entityID($0),$0) })
        let baselineMessages = Dictionary(uniqueKeysWithValues: baseline.messages.map { ($0.id,$0) })
        let remoteAgents = owners.filter { $0.value.identity.ownerType == "agent" }.mapValues { $0.identity.ownerId }
        for (key,var e) in entities where e.deletedAt == nil {
            let id = entityID(e); var next = e.data.object; let kind: String
            if e.identity.entityType == "topic" {
                kind = "topic"; guard let t = local.topics.first(where: { $0.id == id }) else { e.deletedAt = now; entities[key] = e; continue }; next["name"] = .string(t.title)
            } else if e.identity.ownerType == "agent" {
                kind = "agent"; guard let a = local.agents.first(where: { $0.id == id }) else { e.deletedAt = now; entities[key] = e; continue }
                next["name"] = .string(a.name); next["systemPrompt"] = .string(a.systemPrompt); next["model"] = .string(a.model)
                // Leave an absent temperature absent until it is actually changed locally.
                if a.temperature != baseline.agents.first(where: { $0.id == id })?.temperature { next["temperature"] = a.temperature.map(JSONValue.number) ?? .null }
            } else {
                kind = "group"; guard let g = local.groups.first(where: { $0.id == id }) else { e.deletedAt = now; entities[key] = e; continue }
                let b = baseline.groups.first { $0.id == id }; next["name"] = .string(g.name)
                if g.memberIds != b?.memberIds { next["members"] = .array(try g.memberIds.map { guard let remote = remoteAgents[$0] else { throw SyncWire.fail("群组含未加入此同步来源的成员，请先在桌面加入") }; return .string(remote) }) }
                if g.mode != b?.mode { guard g.mode != .rotate,g.mode != .mention else { throw SyncWire.fail("此群组模式不能写回桌面，请选依次、随机或仅点名") }; next["mode"] = .string(g.mode == .all ? "sequential" : g.mode.rawValue) }
                if g.systemPrompt != b?.systemPrompt { next["groupPrompt"] = .string(g.systemPrompt) }
                if g.unifiedModel != b?.unifiedModel { next["useUnifiedModel"] = .bool(!g.unifiedModel.isEmpty); next["unifiedModel"] = .string(g.unifiedModel) }
            }
            let hash = SyncWire.dtoHash(.object(next),identity: e.identity)
            if hash != e.configHash { e.data = .object(next); e.configHash = hash; e.updatedAt = versions[kind + "\0" + id] ?? now }; entities[key] = e
        }
        for t in local.topics where !entities.values.contains(where: { $0.identity.entityType == "topic" && entityID($0) == t.id }) {
            guard let owner = owners[t.ownerId],owner.deletedAt == nil else { continue }
            let identity = SyncIdentity(entityType: "topic",ownerType: owner.identity.ownerType,ownerId: owner.identity.ownerId,topicId: t.id)
            var data: [String:JSONValue] = ["id":.string(t.id),"name":.string(t.title),"createdAt":.number(SyncWire.milliseconds(t.createdAt)),"ownerId":.string(identity.ownerId)]
            if identity.ownerType == "agent" { data["locked"] = .bool(false); data["unread"] = .bool(false) }
            var e = SyncEntity(identity: identity,data: .object(data),updatedAt: now); e.localId = t.id; entities[identity.key] = e
        }
        for e in entities.values where e.identity.entityType == "topic" && e.deletedAt == nil {
            let key = e.identity.topicKey,previous = messages[key] ?? [],rows = local.messages.filter { $0.topicID == entityID(e) }; var next: [JSONValue] = []
            for r in rows {
                guard !["connecting","streaming","pending"].contains(r.status) else { throw SyncWire.fail("请等待正在生成或待发送的消息结束后同步") }
                let old = previous.first { ($0["localId"].text.isEmpty ? localID("message",$0["id"].text,owner: key) : $0["localId"].text) == r.id }, before = baselineMessages[r.id]
                if let old,let before,r.content == before.content,r.reasoning == before.reasoning,r.authorName == before.authorName,r.attachments.map(\.hash) == before.attachments.map(\.hash) { next.append(old); continue }
                var raw = old?.object ?? [:]; raw["id"] = old?["id"] ?? .string(r.id); raw["role"] = .string(r.originalRole ?? r.role); raw["content"] = .string(r.reasoning.isEmpty ? r.content : "<think>\(r.reasoning)</think>\n\(r.content)"); raw["timestamp"] = .number(SyncWire.milliseconds(r.createdAt)); raw["topicId"] = .string(e.identity.topicId!)
                if !r.authorName.isEmpty { raw["name"] = .string(r.authorName) }; if let agent = remoteAgents[r.agentID] { raw["agentId"] = .string(agent) }
                raw["attachments"] = .array(try r.attachments.map { a in
                    guard let hash = a.hash,hash.range(of: "^[0-9a-fA-F]{64}$",options: .regularExpression) != nil else { throw SyncWire.fail("新附件尚未登记文件身份，请从文件页收集后再同步") }
                    var v: [String:JSONValue] = ["name":.string(a.name),"type":.string(a.mime),"size":.number(0),"hash":.string(hash)]; if let text = a.text { v["extractedText"] = .string(text) }; return .object(v)
                })
                var warnings = 0; var m = try SyncWire.message(.object(raw),topic: e.identity.topicId!,warnings: &warnings).object
                guard warnings == 0 else { throw SyncWire.fail("新附件身份无效，未写回") }; m["updatedAt"] = .number(versions["message\0" + r.id] ?? now); m["localId"] = .string(r.id); m["contentHash"] = .string(SyncWire.fingerprint(.object(m))); next.append(.object(m))
            }
            for m in previous where !rows.contains(where: { $0.id == (m["localId"].text.isEmpty ? localID("message",m["id"].text,owner: key) : m["localId"].text) }) { messageDeletes[key,default: [:]][m["id"].text] = now }
            // Restoring a message revives it rather than also advertising its tombstone.
            for m in next { messageDeletes[key]?.removeValue(forKey: m["id"].text) }
            if !next.isEmpty || messages[key] != nil { messages[key] = next }
        }
        for e in entities.values where e.identity.entityType == "owner" && e.identity.ownerType == "agent" && e.deletedAt == nil {
            guard let row = local.agents.first(where: { $0.id == entityID(e) }) else { continue }; let key = e.identity.ownerType + "\0" + e.identity.ownerId,old = avatars[key]
            if row.avatarUrl.hasPrefix("data:"),row.avatarUrl != old?["image"].text,let comma = row.avatarUrl.firstIndex(of: ","),let bytes = Data(base64Encoded: String(row.avatarUrl[row.avatarUrl.index(after: comma)...])) {
                avatars[key] = .object(["ownerType":.string(e.identity.ownerType),"ownerId":.string(e.identity.ownerId),"binaryHash":.string(SyncWire.sha(bytes)),"updatedAt":.number(now),"image":.string(row.avatarUrl)])
            } else if old?["image"].text.isEmpty == false,row.avatarUrl.isEmpty { var v = old!.object; v["deletedAt"] = .number(now); v.removeValue(forKey: "image"); avatars[key] = .object(v) }
        }; refreshRoots()
    }
}
