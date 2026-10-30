import Foundation
import GRDB

public struct StoredMessage: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "messages"
    public var id: String
    public var role: String
    public var content: String
    public var reasoning: String
    public var status: String
    public var createdAt: Double
    public init(id: String = UUID().uuidString, role: String, content: String, reasoning: String = "", status: String = "complete", createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.role = role; self.content = content; self.reasoning = reasoning; self.status = status; self.createdAt = createdAt
    }
}
/// DatabasePool uses SQLite WAL. No database work executes on MainActor.
public actor ChatStore {
    private let pool: DatabasePool
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
        try migrations.migrate(pool)
    }
    public static func open(path: String) async throws -> ChatStore { try ChatStore(path: path) }
    public func messages() async throws -> [StoredMessage] {
        try await pool.read { try StoredMessage.fetchAll($0, sql: "SELECT * FROM messages ORDER BY createdAt, rowid") }
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
