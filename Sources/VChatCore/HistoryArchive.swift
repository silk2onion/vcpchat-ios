import Foundation
import GRDB

public struct HistoryArchive: Codable,Sendable,Identifiable,FetchableRecord {
    public var id: String; public var createdAt: Double; public var topicCount: Int; public var messageCount: Int; public var restoredAt: Double?
}
extension ChatStore {
    public func historyArchives() async throws -> [HistoryArchive] {
        try await pool.read { try HistoryArchive.fetchAll($0,sql: "SELECT * FROM historyArchives ORDER BY createdAt DESC") }
    }
    /// SQL copies the archive before deleting anything, within the same WAL transaction.
    /// No full-history JSON array or second copy of every message is assembled in memory.
    @discardableResult public func clearHistory(replacement: ChatTopic) async throws -> HistoryArchive {
        try await pool.write { db in
            guard replacement.ownerType == "agent",try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind='agent' AND id=?",arguments: [replacement.ownerId]) != nil else { throw ClientError.server("请先选择一个有效的主 Agent") }
            let id = UUID().uuidString,at = Date().timeIntervalSince1970
            let topics = try Int.fetchOne(db,sql: "SELECT count(*) FROM library WHERE kind='topic'") ?? 0
            let messages = try Int.fetchOne(db,sql: "SELECT count(*) FROM messages") ?? 0
            try db.execute(sql: "INSERT INTO historyArchives(id,createdAt,topicCount,messageCount) VALUES(?,?,?,?)",arguments: [id,at,topics,messages])
            try db.execute(sql: "INSERT INTO historyItems SELECT ?,kind,id,payload FROM library WHERE kind IN ('agent','group','topic','draft','message-trash','message-revision')",arguments: [id])
            try db.execute(sql: """
                INSERT INTO historyItems SELECT ?,'message',id,CAST(json_object(
                'id',id,'topicID',topicID,'agentID',agentID,'authorName',authorName,'role',role,'content',content,
                'reasoning',reasoning,'status',status,'createdAt',createdAt,'attachments',json(attachments),
                'originalRole',originalRole,'syncNotice',syncNotice) AS BLOB) FROM messages
                """,arguments: [id])
            // Forgetting local history must not manufacture desktop tombstones on the next sync.
            for raw in try Data.fetchAll(db,sql: "SELECT payload FROM library WHERE kind='sync-profile'") {
                var profile = try JSONDecoder().decode(SyncProfile.self,from: raw)
                profile.entities = profile.entities.filter { $0.value.identity.entityType == "owner" }
                profile.messages = [:]; profile.messageDeletes = [:]; profile.refreshRoots()
                try Self.historyPut(db,profile,kind: "sync-profile",id: profile.id)
            }
            try db.execute(sql: "DELETE FROM outbox; DELETE FROM messages; DELETE FROM messageVersions")
            try db.execute(sql: "DELETE FROM library WHERE kind IN ('topic','draft','message-trash','message-revision')")
            try Self.historyPut(db,replacement,kind: "topic",id: replacement.id)
            return HistoryArchive(id: id,createdAt: at,topicCount: topics,messageCount: messages,restoredAt: nil)
        }
    }
    /// Restore once as independent local copies. Never overwrite present edits or reconnect
    /// restored records to a desktop sync namespace; pending messages are never auto-sent.
    public func restoreHistoryCopy(_ archiveID: String) async throws -> [ChatTopic] {
        try await pool.write { db in
            guard let archive = try HistoryArchive.fetchOne(db,sql: "SELECT * FROM historyArchives WHERE id=?",arguments: [archiveID]),archive.restoredAt == nil else { throw ClientError.server("这个备份已经恢复，或已不存在") }
            func rows<T: Decodable>(_ type: T.Type,_ kind: String) throws -> [T] {
                try Data.fetchAll(db,sql: "SELECT payload FROM historyItems WHERE archiveID=? AND kind=? ORDER BY id",arguments: [archiveID,kind]).map { try JSONDecoder().decode(type,from: $0) }
            }
            let topics = try rows(ChatTopic.self,"topic"),agents = try rows(VCPAgent.self,"agent"),groups = try rows(VCPGroup.self,"group")
            var owners: [String:String] = [:],topicIDs: [String:String] = [:],messageIDs: [String:String] = [:]
            // Clone all owners so even a previously synced group and its member settings stay offline.
            for var a in agents { let old = a.id; a.id = UUID().uuidString; owners[old] = a.id; a.name += " · 恢复"; try Self.historyPut(db,a,kind: "agent",id: a.id) }
            for var g in groups { let old = g.id; g.id = UUID().uuidString; owners[old] = g.id; g.name += " · 恢复"; g.memberIds = g.memberIds.compactMap { owners[$0] }; try Self.historyPut(db,g,kind: "group",id: g.id) }
            var restored: [ChatTopic] = []
            for var t in topics {
                let old = t.id; t.id = UUID().uuidString; topicIDs[old] = t.id
                if let owner = owners[t.ownerId] { t.ownerId = owner }
                else {
                    let a = VCPAgent(name: "历史联系人 · 恢复"); t.ownerType = "agent"; t.ownerId = a.id
                    try Self.historyPut(db,a,kind: "agent",id: a.id)
                }
                t.title += " · 恢复"; try Self.historyPut(db,t,kind: "topic",id: t.id); restored.append(t)
            }
            func remap(_ original: StoredMessage) -> StoredMessage? {
                guard let topic = topicIDs[original.topicID] else { return nil }
                var m = original
                if messageIDs[m.id] == nil { messageIDs[m.id] = UUID().uuidString }
                m.id = messageIDs[m.id]!; m.topicID = topic; m.agentID = owners[m.agentID] ?? ""
                if ["connecting","streaming"].contains(m.status) { m.status = "interrupted" }; return m
            }
            let cursor = try Row.fetchCursor(db,sql: "SELECT payload FROM historyItems WHERE archiveID=? AND kind='message' ORDER BY rowid",arguments: [archiveID])
            while let row = try cursor.next() {
                let payload: Data = row["payload"]
                guard let m = remap(try JSONDecoder().decode(StoredMessage.self,from: payload)) else { throw ClientError.server("备份中有消息缺少对应话题，未恢复") }
                try m.insert(db)
                if m.status == "pending" { try db.execute(sql: "INSERT INTO outbox(id,payload,state) VALUES(?,?,'pending')",arguments: [m.id,try JSONEncoder().encode(m)]) }
            }
            for kind in ["message-trash","message-revision"] {
                let cursor = try Row.fetchCursor(db,sql: "SELECT payload FROM historyItems WHERE archiveID=? AND kind=? ORDER BY rowid",arguments: [archiveID,kind])
                while let row = try cursor.next() {
                    let data: Data = row["payload"]; var b = try JSONDecoder().decode(MessageBackup.self,from: data)
                    guard let m = remap(b.message) else { continue }; b.message = m; b.id = kind == "message-trash" ? m.id : UUID().uuidString
                    try Self.historyPut(db,b,kind: kind,id: b.id)
                }
            }
            let drafts = try Row.fetchCursor(db,sql: "SELECT id,payload FROM historyItems WHERE archiveID=? AND kind='draft'",arguments: [archiveID])
            while let row = try drafts.next() {
                let old: String = row["id"],data: Data = row["payload"]
                guard let id = topicIDs[old] else { continue }
                var value = try JSONDecoder().decode(JSONValue.self,from: data).object; value["id"] = .string(id)
                try Self.historyPut(db,JSONValue.object(value),kind: "draft",id: id)
            }
            try db.execute(sql: "UPDATE historyArchives SET restoredAt=? WHERE id=?",arguments: [Date().timeIntervalSince1970,archiveID])
            return restored
        }
    }
    private static func historyPut<T: Encodable>(_ db: Database,_ value: T,kind: String,id: String) throws {
        try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt",arguments: [kind,id,try JSONEncoder().encode(value),Date().timeIntervalSince1970])
    }
}
