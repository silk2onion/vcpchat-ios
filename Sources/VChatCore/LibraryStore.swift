import Foundation
import GRDB

extension ChatStore {
    public func records<T: Decodable & Sendable>(_ type: T.Type, kind: String) async throws -> [T] {
        try await pool.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM library WHERE kind=? ORDER BY updatedAt DESC", arguments: [kind]).map { try JSONDecoder().decode(type, from: $0) }
        }
    }
    public func put<T: Encodable & Sendable>(_ value: T, kind: String, id: String) async throws {
        let data = try JSONEncoder().encode(value)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt", arguments: [kind, id, data, Date().timeIntervalSince1970])
        }
    }
    public func removeRecord(kind: String, id: String) async throws {
        try await pool.write { try $0.execute(sql: "DELETE FROM library WHERE kind=? AND id=?", arguments: [kind, id]) }
    }
    public func removeTopic(_ id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id IN (SELECT id FROM messages WHERE topicID=?)", arguments: [id])
            try db.execute(sql: "DELETE FROM messages WHERE topicID=?", arguments: [id])
            try db.execute(sql: "DELETE FROM library WHERE kind='draft' AND id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM library WHERE kind='topic' AND id=?", arguments: [id])
        }
    }
    public func removeMessage(_ id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM messages WHERE id=?", arguments: [id])
        }
    }
}
