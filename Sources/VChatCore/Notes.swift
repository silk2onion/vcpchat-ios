import Foundation
import GRDB
public struct LocalNote: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var title = "未命名笔记"
    public var body = ""
    public var updatedAt = Date().timeIntervalSince1970
    public init() {}
}
extension ChatStore {
    public func saveNote(_ note: LocalNote) async throws {
        try await pool.write { db in
            if let old = try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind='note' AND id=?",arguments: [note.id]) {
                try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES('note-revision',?,?,?)",arguments: [UUID().uuidString,old,Date().timeIntervalSince1970])
            }
            try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES('note',?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt",arguments: [note.id,try JSONEncoder().encode(note),note.updatedAt])
        }
    }
    public func trashNote(_ note: LocalNote, restoring: Bool = false) async throws {
        try await pool.write { db in
            let from = restoring ? "note-trash" : "note", to = restoring ? "note" : "note-trash"
            guard let saved = try Data.fetchOne(db,sql: "SELECT payload FROM library WHERE kind=? AND id=?",arguments: [from,note.id]) else { return }
            guard try !Bool.fetchOne(db,sql: "SELECT EXISTS(SELECT 1 FROM library WHERE kind=? AND id=?)",arguments: [to,note.id])! else { throw ClientError.server("同名记录已存在，不会覆盖") }
            try db.execute(sql: "INSERT INTO library(kind,id,payload,updatedAt) VALUES(?,?,?,?)",arguments: [to,note.id,saved,Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM library WHERE kind=? AND id=?",arguments: [from,note.id])
        }
    }
}
public enum NotePath {
    public static func segment(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"), !value.unicodeScalars.contains(where: { $0.value <= 31 }) else { throw ClientError.server("文件夹或文件名无效") }; return value
    }
    public static func filename(_ value: String) throws -> String { let name = try segment(value); return name.contains(".") ? name : name + ".txt" }
}
public struct RemoteNote: Codable, Sendable, Identifiable, Equatable {
    public var folder: String; public var file: String; public var lastModified: String; public var preview: String
    public var id: String { folder + "/" + file }
    public init(folder: String,file: String,lastModified: String = "",preview: String = "") { self.folder = folder; self.file = file; self.lastModified = lastModified; self.preview = preview }
}
public actor DailyNotesClient {
    let http = VCPHTTP()
    public init() {}
    func call(_ configuration: ConnectionConfiguration, username: String, password: String, path: [String], query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { throw ClientError.server("请先设置日记管理员用户名和密码") }
        var url = try configuration.endpoint("admin_api/dailynotes")
        for segment in path { url.appendPathComponent(try NotePath.segment(segment)) }
        var parts = URLComponents(url: url,resolvingAgainstBaseURL: false)!; if !query.isEmpty { parts.queryItems = query }
        let auth = "Basic " + Data((username.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + password).utf8).base64EncodedString()
        return try await http.json(parts.url!,method: body == nil ? "GET" : "POST",authorization: auth,body: body)
    }
    public func folders(_ config: ConnectionConfiguration, username: String, password: String) async throws -> [String] {
        let value = try await call(config,username: username,password: password,path: ["folders"])
        guard case .array(let folders) = value["folders"] else { throw ClientError.invalidResponse }; return folders.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }
    func summaries(_ value: JSONValue, fallback: String) -> [RemoteNote] {
        value.array.map { row in RemoteNote(folder: row["folderName"].text.isEmpty ? (row["folder"].text.isEmpty ? fallback : row["folder"].text) : row["folderName"].text,file: row["name"].text.isEmpty ? row["file"].text : row["name"].text,lastModified: row["lastModified"].text.isEmpty ? row["last_modified"].text : row["lastModified"].text,preview: row["preview"].text) }
    }
    public func notes(_ config: ConnectionConfiguration, username: String, password: String, folder: String, query: String = "") async throws -> [RemoteNote] {
        let folder = try NotePath.segment(folder)
        let value = try await call(config,username: username,password: password,path: query.isEmpty ? ["folder",folder] : ["search"],query: query.isEmpty ? [] : [URLQueryItem(name: "term",value: query.trimmingCharacters(in: .whitespacesAndNewlines)),URLQueryItem(name: "folder",value: folder)])
        let rows = value["notes"] == .null ? value["memos"] : value["notes"]
        guard case .array = rows else { throw ClientError.invalidResponse }; return summaries(rows,fallback: folder)
    }
    public func read(_ config: ConnectionConfiguration, username: String, password: String, folder: String, file: String) async throws -> String {
        let value = try await call(config,username: username,password: password,path: ["note",folder,file])
        guard case .string(let text) = value["content"] else { throw ClientError.invalidResponse }; return text
    }
    public func save(_ config: ConnectionConfiguration, username: String, password: String, folder: String, file: String, content: String) async throws {
        _ = try await call(config,username: username,password: password,path: ["note",folder,try NotePath.filename(file)],body: .object(["content": .string(content)]))
    }
}
