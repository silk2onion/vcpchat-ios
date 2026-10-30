import Foundation
import GRDB
public struct SyncCheckpoint: Codable,Sendable,Identifiable {
    public var id: String; public var profileID: String; public var at: Double; public var before: SyncSnapshot; public var after: SyncSnapshot; public var previous: SyncProfile
}
extension ChatStore {
    static func snapshot(_ db: Database) throws -> SyncSnapshot {
        func rows<T: Decodable>(_ type: T.Type,_ kind: String) throws -> [T] { try Data.fetchAll(db,sql: "SELECT payload FROM library WHERE kind=? ORDER BY id",arguments: [kind]).map { try JSONDecoder().decode(type,from: $0) } }
        var s = SyncSnapshot(); s.agents = try rows(VCPAgent.self,"agent"); s.groups = try rows(VCPGroup.self,"group"); s.topics = try rows(ChatTopic.self,"topic"); s.messages = try StoredMessage.fetchAll(db,sql: "SELECT * FROM messages ORDER BY id"); return s
    }
    public func syncSnapshot() async throws -> SyncSnapshot { try await pool.read { try Self.snapshot($0) } }
    public func syncVersions() async throws -> [String:Double] {
        try await pool.read { db in
            var out: [String:Double] = [:]
            for r in try Row.fetchAll(db,sql: "SELECT kind,id,updatedAt FROM library WHERE kind IN ('agent','group','topic')") { out[(r["kind"] as String) + "\0" + (r["id"] as String)] = SyncWire.milliseconds(r["updatedAt"]) }
            for r in try Row.fetchAll(db,sql: "SELECT id,updatedAt FROM messageVersions") { let at: Double = r["updatedAt"]; out["message\0" + (r["id"] as String)] = at.rounded() }
            return out
        }
    }
    /// All scope replacement and the recovery checkpoint commit in one WAL transaction.
    public func commitSync(profile: SyncProfile,previous: SyncProfile,before: SyncSnapshot,after: SyncSnapshot,expectedSettings: MobileSyncSettings? = nil) async throws {
        guard profile.id == previous.id,profile.endpoint == previous.endpoint else { throw SyncWire.fail("同步来源身份不匹配") }
        try Task.checkCancellation()
        try await pool.write { db in
            try Task.checkCancellation()
            let current = try Self.snapshot(db).managed(by: previous)
            guard current.ordered() == before.ordered() else { throw SyncWire.fail("同步期间本机内容已改变，本次未写入；请重试") }
            if let raw = try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind='sync-profile' AND id=?",arguments: [previous.id]) {
                guard try JSONDecoder().decode(SyncProfile.self,from: raw) == previous else { throw SyncWire.fail("同步来源已改变，本次未写入") }
            } else { guard previous.entities.isEmpty,previous.messages.isEmpty else { throw SyncWire.fail("同步来源已移除") } }
            if let expectedSettings,let raw = try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind='services' AND id='settings'") {
                guard try JSONDecoder().decode(ServiceSettings.self,from: raw).sync == expectedSettings else { throw SyncWire.fail("同步设置已改变，本次未写入") }
            }
            let checkpoint = SyncCheckpoint(id: UUID().uuidString,profileID: profile.id,at: Date().timeIntervalSince1970,before: before,after: after,previous: previous)
            try Self.replaceSync(db,profile: profile,before: current,after: after)
            try Self.putSync(db,checkpoint,kind: "sync-checkpoint",id: checkpoint.id)
            try Self.putSync(db,profile,kind: "sync-profile",id: profile.id)
        }
    }
    public func restoreSync(_ checkpoint: SyncCheckpoint) async throws {
        try await pool.write { db in
            guard let raw = try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind='sync-checkpoint' AND id=?",arguments: [checkpoint.id]) else { throw SyncWire.fail("恢复点不存在") }
            let checkpoint = try JSONDecoder().decode(SyncCheckpoint.self,from: raw)
            guard checkpoint.previous.id == checkpoint.profileID else { throw SyncWire.fail("恢复点来源身份不匹配") }
            guard let p = try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind='sync-profile' AND id=?",arguments: [checkpoint.profileID]) else { throw SyncWire.fail("同步来源不存在") }
            let previous = try JSONDecoder().decode(SyncProfile.self,from: p),before = try Self.snapshot(db).managed(by: previous)
            let backup = SyncCheckpoint(id: UUID().uuidString,profileID: previous.id,at: Date().timeIntervalSince1970,before: before,after: checkpoint.before,previous: previous)
            try Self.replaceSync(db,profile: checkpoint.previous,before: before,after: checkpoint.before)
            try Self.putSync(db,backup,kind: "sync-checkpoint",id: backup.id); try Self.putSync(db,checkpoint.previous,kind: "sync-profile",id: previous.id)
        }
    }
    private static func putSync<T: Encodable>(_ db: Database,_ value: T,kind: String,id: String) throws {
        try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt",arguments: [kind,id,try JSONEncoder().encode(value),Date().timeIntervalSince1970])
    }
    private static func replaceSync(_ db: Database,profile: SyncProfile,before: SyncSnapshot,after: SyncSnapshot) throws {
        let prefix = "sync:\(profile.id):",all = try snapshot(db)
        let ownerIDs = after.agents.map(\.id) + after.groups.map(\.id),topicIDs = after.topics.map(\.id),messageIDs = after.messages.map(\.id)
        guard Set(ownerIDs).count == ownerIDs.count,Set(topicIDs).count == topicIDs.count,Set(messageIDs).count == messageIDs.count,ownerIDs.allSatisfy({ $0.hasPrefix(prefix) }),after.topics.allSatisfy({ ownerIDs.contains($0.ownerId) }),after.messages.allSatisfy({ topicIDs.contains($0.topicID) }) else { throw SyncWire.fail("同步记录超出来源范围或有重复身份") }
        let foreign = all.managedExcluding(profile)
        guard Set(ownerIDs).isDisjoint(with: Set(foreign.agents.map(\.id) + foreign.groups.map(\.id))),Set(topicIDs).isDisjoint(with: Set(foreign.topics.map(\.id))),Set(messageIDs).isDisjoint(with: Set(foreign.messages.map(\.id))) else { throw SyncWire.fail("同步身份与本机记录冲突，未覆盖") }
        for t in before.topics {
            try db.execute(sql: "DELETE FROM outbox WHERE id IN (SELECT id FROM messages WHERE topicID=?)",arguments: [t.id]); try db.execute(sql: "DELETE FROM messages WHERE topicID=?",arguments: [t.id])
            try db.execute(sql: "DELETE FROM library WHERE kind='topic' AND id=?",arguments: [t.id])
            // Drafts are user input: leave them intact even when a remote topic is removed.
        }
        for id in before.agents.map(\.id) { try db.execute(sql: "DELETE FROM library WHERE kind='agent' AND id=?",arguments: [id]) }
        for id in before.groups.map(\.id) { try db.execute(sql: "DELETE FROM library WHERE kind='group' AND id=?",arguments: [id]) }
        for a in after.agents { try putSync(db,a,kind: "agent",id: a.id) }; for g in after.groups { try putSync(db,g,kind: "group",id: g.id) }; for t in after.topics { try putSync(db,t,kind: "topic",id: t.id) }
        for var m in after.messages {
            for i in m.attachments.indices where m.attachments[i].desktopOnly == true {
                guard let hash = m.attachments[i].hash,let row = try Row.fetchOne(db,sql: "SELECT mime,bytes FROM files WHERE id=? AND removedAt IS NULL",arguments: [hash]) else { continue }
                let data: Data = row["bytes"],mime: String = row["mime"]
                if mime.hasPrefix("image/"),mime != "image/svg+xml",data.count <= 1_500_000 { m.attachments[i].dataUrl = "data:\(mime);base64," + data.base64EncodedString(); m.attachments[i].desktopOnly = false }
                else if (mime.hasPrefix("text/") || ["application/json","application/xml"].contains(mime)),data.count <= 200_000,let text = String(data: data,encoding: .utf8) { m.attachments[i].text = text; m.attachments[i].desktopOnly = false }
            }; try m.save(db)
        }
    }
}
extension SyncSnapshot {
    fileprivate func managedExcluding(_ p: SyncProfile) -> Self {
        let own = managed(by: p),ownerIDs = Set(own.agents.map(\.id) + own.groups.map(\.id)),topicIDs = Set(own.topics.map(\.id)),messageIDs = Set(own.messages.map(\.id))
        var out = Self(); out.agents = agents.filter { !ownerIDs.contains($0.id) }; out.groups = groups.filter { !ownerIDs.contains($0.id) }; out.topics = topics.filter { !topicIDs.contains($0.id) }; out.messages = messages.filter { !messageIDs.contains($0.id) }; return out
    }
}
