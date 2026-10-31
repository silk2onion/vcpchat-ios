import Foundation
import GRDB

public struct MessageBackup: Codable, Sendable, Identifiable {
    public var id: String
    public var message: StoredMessage
    public var createdAt: Double
}
extension ChatStore {
    /// Keep the previous value in the same transaction as the edit.
    public func reviseMessage(_ message: StoredMessage) async throws {
        try await pool.write { db in
            guard let old = try StoredMessage.fetchOne(db, key: message.id) else { throw ClientError.server("这条消息已经不存在") }
            let backup = MessageBackup(id: UUID().uuidString, message: old, createdAt: Date().timeIntervalSince1970)
            try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES('message-revision',?,?,?)", arguments: [backup.id, try JSONEncoder().encode(backup), backup.createdAt])
            try message.save(db)
            if message.status == "pending" { try db.execute(sql: "UPDATE outbox SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(message), message.id]) }
        }
    }
    public func trashMessage(_ id: String) async throws {
        try await pool.write { db in
            guard let message = try StoredMessage.fetchOne(db, key: id) else { return }
            let backup = MessageBackup(id: id, message: message, createdAt: Date().timeIntervalSince1970)
            try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES('message-trash',?,?,?)", arguments: [id, try JSONEncoder().encode(backup), backup.createdAt])
            try db.execute(sql: "DELETE FROM outbox WHERE id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM messages WHERE id=?", arguments: [id])
        }
    }
    public func restoreMessage(_ backup: MessageBackup) async throws {
        try await pool.write { db in
            guard try !StoredMessage.exists(db, key: backup.message.id) else { throw ClientError.server("同一条消息已经存在，不会覆盖") }
            guard try Data.fetchOne(db, sql: "SELECT payload FROM library WHERE kind='message-trash' AND id=?", arguments: [backup.id]) != nil else { throw ClientError.server("这条消息已经恢复") }
            try backup.message.insert(db)
            if backup.message.status == "pending" { try db.execute(sql: "INSERT INTO outbox(id,payload,state) VALUES(?,?,'pending')", arguments: [backup.message.id, try JSONEncoder().encode(backup.message)]) }
            try db.execute(sql: "DELETE FROM library WHERE kind='message-trash' AND id=?", arguments: [backup.id])
        }
    }
}
public enum TranscriptExport {
    public static func markdown(title: String, messages: [StoredMessage]) -> String {
        "# " + title.replacingOccurrences(of: "\n", with: " ") + "\n\n" + messages.map { "## " + ($0.role == "user" ? ($0.authorName.isEmpty ? "我" : $0.authorName) : $0.authorName) + "\n\n" + $0.content + "\n\n" }.joined()
    }
}
