import Foundation
import CryptoKit
import UniformTypeIdentifiers
import GRDB

public struct LocalFile: Codable, Sendable, Equatable, Identifiable, FetchableRecord {
    public var id: String; public var name: String; public var mime: String; public var size: Int
    public var addedAt: Double; public var source: String; public var removedAt: Double?
}
public actor LocalFileImporter {
    public init() {}
    public func read(_ url: URL) throws -> (String, String, Data) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20_000_000 else { throw ClientError.server("本机文件库单个文件上限 20 MB") }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw ClientError.server("本机文件库单个文件上限 20 MB") }
        return (url.lastPathComponent, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data)
    }
}
extension ChatStore {
    public func localFiles(removed: Bool = false) async throws -> [LocalFile] {
        try await pool.read { db in try LocalFile.fetchAll(db, sql: "SELECT id,name,mime,size,addedAt,source,removedAt FROM files WHERE removedAt IS \(removed ? "NOT NULL" : "NULL") ORDER BY addedAt DESC") }
    }
    public func fileBytes(_ id: String) async throws -> Data {
        try await pool.read { db in guard let value = try Data.fetchOne(db, sql: "SELECT bytes FROM files WHERE id=?", arguments: [id]) else { throw ClientError.server("原文件不存在") }; return value }
    }
    @discardableResult public func addFile(name: String, mime: String, bytes: Data, source: String = "本机导入") async throws -> LocalFile {
        guard bytes.count <= 20_000_000 else { throw ClientError.server("本机文件库单个文件上限 20 MB") }
        // The hash is the protocol identity and deduplication key, not a verification checksum.
        let id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try await pool.write { db in
            try db.execute(sql: "INSERT INTO files(id,name,mime,size,addedAt,source,bytes) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET removedAt=NULL", arguments: [id,name,mime,bytes.count,Date().timeIntervalSince1970,source,bytes])
            let file = try LocalFile.fetchOne(db, sql: "SELECT id,name,mime,size,addedAt,source,removedAt FROM files WHERE id=?",arguments: [id])!
            let topics = try Data.fetchAll(db,sql: "SELECT payload FROM library WHERE kind='topic'").map { try JSONDecoder().decode(ChatTopic.self,from: $0) }
            for topic in topics where topic.ownerId.hasPrefix("sync:") {
                for var message in try StoredMessage.fetchAll(db,sql: "SELECT * FROM messages WHERE topicID=?",arguments: [topic.id]) {
                    var changed = false
                    message.attachments = message.attachments.map { original in
                        guard original.hash == id, original.desktopOnly == true else { return original }
                        var a = original; a.desktopOnly = false
                        if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(file.mime) { a.dataUrl = "data:\(file.mime);base64," + bytes.base64EncodedString() }
                        if (file.mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(file.mime)) && bytes.count <= 200_000 { a.text = String(decoding: bytes,as: UTF8.self) }
                        changed = true; return a
                    }
                    if changed { try message.save(db) }
                }
            }
            return file
        }
    }
    public func setFileRemoved(_ id: String, removed: Bool) async throws {
        try await pool.write { db in try db.execute(sql: "UPDATE files SET removedAt=? WHERE id=?",arguments: [removed ? Date().timeIntervalSince1970 : nil,id]) }
    }
    public func collectAttachmentFiles() async throws -> Int {
        var count = 0
        for message in try await messages() { for a in message.attachments where a.desktopOnly != true {
            if let bytes = a.bytes { try await addFile(name: a.name,mime: a.mime,bytes: bytes,source: "聊天附件副本"); count += 1 }
        } }
        try await pool.write { db in
            for var message in try StoredMessage.fetchAll(db) {
                var changed = false
                for i in message.attachments.indices where message.attachments[i].hash == nil && message.attachments[i].desktopOnly != true {
                    if let bytes = message.attachments[i].bytes { message.attachments[i].hash = SyncWire.sha(bytes); changed = true }
                }
                if changed { try message.save(db) }
            }
        }
        return count
    }
}
