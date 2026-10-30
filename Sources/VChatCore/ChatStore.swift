import Foundation
import GRDB

public struct StoredMessage: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "messages"
    public var id: String
    public var topicID: String
    public var agentID: String
    public var authorName: String
    public var role: String
    public var content: String
    public var reasoning: String
    public var status: String
    public var createdAt: Double
    public var attachments: [ChatAttachment]
    public var originalRole: String?
    public var syncNotice: String?
    public init(id: String = UUID().uuidString, topicID: String = "legacy", agentID: String = "", authorName: String = "助手", role: String, content: String, reasoning: String = "", status: String = "complete", createdAt: Double = Date().timeIntervalSince1970, attachments: [ChatAttachment] = [], originalRole: String? = nil, syncNotice: String? = nil) {
        self.attachments = attachments; self.originalRole = originalRole; self.syncNotice = syncNotice
        self.topicID = topicID; self.agentID = agentID; self.authorName = authorName
        self.id = id; self.role = role; self.content = content; self.reasoning = reasoning; self.status = status; self.createdAt = createdAt
    }
    enum CodingKeys: String, CodingKey { case id, topicID, agentID, authorName, role, content, reasoning, status, createdAt, attachments, originalRole, syncNotice }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), topicID: try c.decodeIfPresent(String.self, forKey: .topicID) ?? "legacy", agentID: try c.decodeIfPresent(String.self, forKey: .agentID) ?? "", authorName: try c.decodeIfPresent(String.self, forKey: .authorName) ?? "助手", role: try c.decode(String.self, forKey: .role), content: try c.decode(String.self, forKey: .content), reasoning: try c.decodeIfPresent(String.self, forKey: .reasoning) ?? "", status: try c.decodeIfPresent(String.self, forKey: .status) ?? "complete", createdAt: try c.decode(Double.self, forKey: .createdAt), attachments: try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? [], originalRole: try c.decodeIfPresent(String.self, forKey: .originalRole), syncNotice: try c.decodeIfPresent(String.self, forKey: .syncNotice))
    }

}
/// DatabasePool uses SQLite WAL. No database work executes on MainActor.
public actor ChatStore {
    let pool: DatabasePool
    public init(path: String) throws {
        pool = try DatabasePool(path: path)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("native-v1") { db in
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey(); t.column("role", .text).notNull(); t.column("content", .text).notNull()
                t.column("reasoning", .text).notNull(); t.column("status", .text).notNull(); t.column("createdAt", .double).notNull()
            }
            try db.create(virtualTable: "messageSearch", using: FTS5()) { t in
                t.synchronize(withTable: "messages"); t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"]); t.column("content")
            }
            try db.create(table: "outbox") { t in t.column("id", .text).primaryKey(); t.column("payload", .blob).notNull(); t.column("state", .text).notNull() }
        }
        migrations.registerMigration("native-v2-library") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "topicID", .text).notNull().defaults(to: "legacy")
                t.add(column: "agentID", .text).notNull().defaults(to: "")
                t.add(column: "authorName", .text).notNull().defaults(to: "助手")
            }
            try db.create(index: "messages_topic", on: "messages", columns: ["topicID", "createdAt"])
            try db.create(table: "library") { t in
                t.column("kind", .text).notNull(); t.column("id", .text).notNull()
                t.column("payload", .blob).notNull(); t.column("updatedAt", .double).notNull()
                t.primaryKey(["kind", "id"])
            }
        }
        migrations.registerMigration("native-v3-attachments") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "attachments", .text).notNull().defaults(to: "[]")
                t.add(column: "originalRole", .text); t.add(column: "syncNotice", .text)
            }
        }
        migrations.registerMigration("native-v4-files") { db in
            try db.create(table: "files") { t in
                t.column("id", .text).primaryKey(); t.column("name", .text).notNull(); t.column("mime", .text).notNull(); t.column("size", .integer).notNull()
                t.column("addedAt", .double).notNull(); t.column("source", .text).notNull(); t.column("bytes", .blob).notNull(); t.column("removedAt", .double)
            }
        }
        migrations.registerMigration("native-v5-sync-versions") { db in
            try db.create(table: "messageVersions") { t in t.column("id",.text).primaryKey(); t.column("updatedAt",.double).notNull() }
            for event in ["INSERT","UPDATE"] {
                try db.execute(sql: "CREATE TRIGGER message_versions_\(event.lowercased()) AFTER \(event) ON messages BEGIN INSERT INTO messageVersions(id,updatedAt) VALUES(new.id,(julianday('now')-2440587.5)*86400000) ON CONFLICT(id) DO UPDATE SET updatedAt=excluded.updatedAt; END")
            }
        }
        try migrations.migrate(pool)
    }
    public static func open(path: String) async throws -> ChatStore { try ChatStore(path: path) }
    public func messages(topicID: String? = nil) async throws -> [StoredMessage] {
        try await pool.read { db in
            if let topicID { return try StoredMessage.fetchAll(db, sql: "SELECT * FROM messages WHERE topicID=? ORDER BY createdAt, rowid", arguments: [topicID]) }
            return try StoredMessage.fetchAll(db, sql: "SELECT * FROM messages ORDER BY createdAt, rowid")
        }
    }
    public func save(_ message: StoredMessage) async throws { try await pool.write { try message.save($0) } }
    public func enqueue(_ message: StoredMessage) async throws {
        let payload = try JSONEncoder().encode(message)
        try await pool.write { db in
            try message.save(db)
            try db.execute(sql: "INSERT INTO outbox(id,payload,state) VALUES(?,?,'pending')", arguments: [message.id, payload])
        }
    }
    public func markSent(_ id: String) async throws { try await pool.write { db in try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id]); try db.execute(sql: "UPDATE messages SET status='complete' WHERE id = ?", arguments: [id]) } }
    public func pending() async throws -> Int { try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") ?? 0 } }
    public func recoverInterrupted() async throws { try await pool.write { try $0.execute(sql: "UPDATE messages SET status='interrupted' WHERE status IN ('streaming','connecting')") } }
    public func search(_ text: String) async throws -> [StoredMessage] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // Quote the literal query; user input is not an FTS expression or SQL fragment.
        let query = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try await pool.read { db in
            try StoredMessage.fetchAll(db, sql: "SELECT messages.* FROM messages JOIN messageSearch ON messages.rowid=messageSearch.rowid WHERE messageSearch MATCH ? ORDER BY rank LIMIT 100", arguments: [query])
        }
    }
    public func journalMode() async throws -> String { try await pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") ?? "" } }
}
