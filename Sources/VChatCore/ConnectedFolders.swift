import Foundation
import Darwin
import CryptoKit

// Ported from the previous client's ConnectedFolders.swift; native Actor replaces the Tauri C bridge.
private let fileLimit = 20_000_000
private let treeLimit = 100_000_000
private let entryLimit = 2000
private func failure(_ code: String, _ message: String) -> NSError {
    NSError(domain: "VCPFolders.\(code)", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(code)：\(message)"])
}
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
private func inside(_ child: URL, _ parent: URL) -> Bool {
    let p = parent.standardizedFileURL.path, c = child.standardizedFileURL.path
    return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
}
private struct Folder: Codable {
    var id: String; var name: String; var bookmark: Data; var agentAccess: String; var connected: Bool
}
private struct Backup: Codable {
    var id: String; var folderId: String; var path: String; var operation: String; var createdAt: Int64; var directory: Bool
}
private struct Receipt: Codable { var signature: String; var result: Data?; var at: Int64; var error: String? }
private struct Registry: Codable {
    var folders: [Folder] = []; var backups: [Backup] = []; var receipts: [String: Receipt] = [:]
}

final class ConnectedFolderEngine {
    let storage: URL
    private let fm = FileManager.default
    private var registry: Registry
    private var persisted: Registry
    init(storage: URL) throws {
        self.storage = storage.standardizedFileURL
        try fm.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = storage.appendingPathComponent("registry.json")
        let initial = fm.fileExists(atPath: index.path) ? try JSONDecoder().decode(Registry.self, from: Data(contentsOf: index)) : Registry()
        registry = initial; persisted = initial
    }
    private func save() throws {
        let temporary = storage.appendingPathComponent(".registry-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        do {
            let data = try JSONEncoder().encode(registry), index = storage.appendingPathComponent("registry.json")
            try data.write(to: temporary, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            let renamed = temporary.path.withCString { source in index.path.withCString { target in Darwin.rename(source, target) } }
            guard renamed == 0 else { throw NSError(domain:NSPOSIXErrorDomain, code:Int(errno)) }
            persisted = registry
        } catch { registry = persisted; throw error }
    }
    private func bookmark(_ url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    private func resolve(_ folder: Folder) throws -> (URL, Bool) {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return (url, stale)
    }
    private func scoped<T>(_ id: String, agent: Bool, writing: Bool = false, _ body: (URL) throws -> T) throws -> T {
        guard let index = registry.folders.firstIndex(where: { $0.id == id && $0.connected }) else { throw failure("NOT_CONNECTED", "文件夹已断开，请重新连接") }
        let folder = registry.folders[index]
        if agent && (!["read","write"].contains(folder.agentAccess) || (writing && folder.agentAccess != "write")) { throw failure("NOT_AUTHORIZED", "此文件夹未授权 Agent 执行这项操作") }
        let (url, stale): (URL, Bool)
        do { (url, stale) = try resolve(folder) } catch { throw failure("AUTH_EXPIRED", "文件夹授权不可用，请重新连接") }
        let granted = url.startAccessingSecurityScopedResource()
        #if os(iOS)
        guard granted else { throw failure("AUTH_EXPIRED", "文件夹授权已失效，请重新连接") }
        #endif
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw failure("UNAVAILABLE", "文件夹暂时不可用，请检查文件提供者或重新连接") }
        if stale { registry.folders[index].bookmark = try bookmark(url); try save() }
        return try body(url.standardizedFileURL)
    }
    private func coordinate<T>(_ url: URL, write: Bool, destination: URL? = nil, command: String = "", _ body: (URL, URL?) throws -> T) throws -> T {
        var coordinationError: NSError?, outcome: Result<T, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let moving = command == "MoveFile" || command == "RenameFile"
        let options: NSFileCoordinator.WritingOptions = moving ? .forMoving : command == "DeleteFile" ? .forDeleting : []
        if let destination = destination {
            coordinator.coordinate(writingItemAt: url, options: options, writingItemAt: destination, options: [], error: &coordinationError) { a,b in
                #if os(macOS)
                if moving && ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { coordinator.item(at:a, willMoveTo:b) }
                #endif
                let result = Result { try body(a,b) }
                if moving { if case .success = result { coordinator.item(at:a, didMoveTo:b) } else { coordinator.item(at:a, didMoveTo:a) } }
                outcome = result
            }
        } else if write {
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { a in outcome = Result { try body(a,nil) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { a in outcome = Result { try body(a,nil) } }
        }
        if let error = coordinationError { throw error }
        guard let result = outcome else { throw failure("COORDINATION_FAILED", "文件提供者没有完成访问协调") }
        return try result.get()
    }
    // Reject absolute paths, traversal and every symlink component. Never trust a model's absolute URL.
    private func path(_ relative: String, root: URL, allowRoot: Bool = false) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains(":"), !relative.unicodeScalars.contains(where: { $0.value < 32 }) else { throw failure("INVALID_PATH", "请使用授权文件夹内的相对路径") }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        if relative.isEmpty { if allowRoot { return root }; throw failure("INVALID_PATH", "不能修改连接的根目录") }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw failure("INVALID_PATH", "路径含无效层级") }
        var current = root
        for part in parts {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw failure("SYMLINK", "不操作符号链接，请连接实际文件夹") }
        }
        let resolved = current.resolvingSymlinksInPath()
        guard inside(resolved, root.resolvingSymlinksInPath()), !inside(resolved, storage) else { throw failure("OUTSIDE_FOLDER", "目标不在授权范围内") }
        return current
    }
    private func data(_ url: URL, limit: Int = fileLimit) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? limit + 1) <= limit else { throw failure("FILE_LIMIT", "文件过大或不是普通文件（App上限20MB，Agent读取上限200KB）") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk); guard bytes.count <= limit else { throw failure("FILE_LIMIT", "文件超过读取上限") }
        }
        return bytes
    }
    private func version(_ url: URL) throws -> String {
        if !fm.fileExists(atPath: url.path) { return "missing" }
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        return v.isDirectory == true ? "directory:\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)" : digest(try data(url))
    }
    private func expected(_ args: [String: Any], _ url: URL) throws {
        guard let expected = args["expectedVersion"] as? String, !expected.isEmpty else { throw failure("VERSION_REQUIRED", "请先读取文件或属性，带上版本后再修改") }
        guard try version(url) == expected else { throw failure("CONFLICT", "文件已被其他操作修改，请重新读取；未覆盖") }
    }
    private func checkTree(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        var total = 0, count = 0
        func check(_ item: URL) throws {
            let v = try item.resourceValues(forKeys: keys)
            guard v.isSymbolicLink != true else { throw failure("SYMLINK", "文件夹含符号链接，未执行修改") }
            if v.isRegularFile == true { let size = v.fileSize ?? treeLimit + 1; guard size <= fileLimit else { throw failure("FILE_LIMIT", "备份中有文件超过20MB，未修改") }; total += size }
            count += 1; guard total <= treeLimit && count <= entryLimit else { throw failure("BACKUP_LIMIT", "本次备份超过100MB或2000个项目，未修改") }
        }
        try check(url)
        if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            var enumerationError: Error?
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _,error in enumerationError = error; return false }) else { throw failure("BACKUP_FAILED", "无法完整枚举备份") }
            for case let item as URL in e { try check(item) }; if let error = enumerationError { throw error }
        }
    }
    private func backup(_ url: URL, folder: String, relative: String, command: String) throws -> Backup {
        try checkTree(url)
        let b = Backup(id: UUID().uuidString, folderId: folder, path: relative, operation: command, createdAt: now(), directory: (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        let dir = storage.appendingPathComponent("backups/\(b.id)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: url, to: dir.appendingPathComponent("original"))
            registry.backups.append(b); try save()
        } catch { registry.backups.removeAll { $0.id == b.id }; try? fm.removeItem(at: dir); throw failure("BACKUP_FAILED", "备份失败，未修改原文件：\(error.localizedDescription)") }
        return b
    }
    private func information(_ url: URL, relative: String) throws -> [String: Any] {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
        return ["name":url.lastPathComponent,"path":relative,"type":v.isSymbolicLink == true ? "symlink" : v.isDirectory == true ? "directory" : "file", "size":v.fileSize ?? 0,"modified":Int64((v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000),"version":v.isSymbolicLink == true ? "blocked" : try version(url)]
    }
    func connect(_ url: URL) throws -> [String: Any] {
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        #if os(iOS)
        guard granted else { throw failure("AUTH_EXPIRED", "文件夹授权已失效，请重新连接") }
        #endif
        guard (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !inside(storage, url), !inside(url, storage) else { throw failure("INVALID_FOLDER", "请选择独立的工作文件夹，不要包含应用内部备份目录") }
        let bytes = try bookmark(url)
        if let i = registry.folders.firstIndex(where: { (try? resolve($0).0.standardizedFileURL) == url.standardizedFileURL }) {
            registry.folders[i].bookmark = bytes; registry.folders[i].connected = true; registry.folders[i].name = url.lastPathComponent; try save(); return folderInfo(registry.folders[i])
        }
        let f = Folder(id: UUID().uuidString, name: url.lastPathComponent, bookmark: bytes, agentAccess: "off", connected: true)
        registry.folders.append(f); try save(); return folderInfo(f)
    }
    private func folderInfo(_ f: Folder) -> [String: Any] { ["id":f.id,"name":f.name,"agentAccess":f.agentAccess] }
    func handle(_ request: [String: Any]) throws -> Any {
        let action = request["action"] as? String ?? ""
        if action == "folders" { return registry.folders.filter { $0.connected }.map(folderInfo) }
        let id = request["folderId"] as? String ?? ""
        if action == "disconnect" {
            if let i = registry.folders.firstIndex(where: { $0.id == id }) { registry.folders[i].connected = false; registry.folders[i].agentAccess = "off" }; try save(); return ["disconnected":true]
        }
        if action == "grant" {
            guard let access = request["access"] as? String, ["off","read","write"].contains(access), let i = registry.folders.firstIndex(where: { $0.id == id }) else { throw failure("INVALID_ACCESS", "授权设置无效") }
            registry.folders[i].agentAccess = access; try save(); return folderInfo(registry.folders[i])
        }
        if action == "backups" { return registry.backups.filter { $0.folderId == id }.sorted { $0.createdAt > $1.createdAt }.map { b in ["id":b.id,"path":b.path,"operation":b.operation,"createdAt":b.createdAt,"directory":b.directory] as [String:Any] } }
        if action == "restore" {
            guard let b = registry.backups.first(where: { $0.id == request["backupId"] as? String && $0.folderId == id }) else { throw failure("NOT_FOUND", "备份不存在") }
            return try scoped(id, agent: false, writing: true) { root in
                let target = try path(b.path, root: root)
                return try coordinate(target, write: true) { target,_ in
                    try expected(request, target)
                    let original = storage.appendingPathComponent("backups/\(b.id)/original")
                    guard !fm.fileExists(atPath: target.path) || !b.directory else { throw failure("EXISTS", "原路径已有文件夹，未覆盖；请先移走该文件夹") }
                    var extra: String? = nil
                    if fm.fileExists(atPath: target.path) { extra = try backup(target, folder: id, relative: b.path, command: "RestoreBackup").id }
                    try checkTree(original)
                    if b.directory { try fm.copyItem(at: original, to: target) } else { try data(original).write(to: target, options: .atomic) }
                    return ["path":b.path,"version":try version(target),"backupId":extra ?? ""] as [String:Any]
                }
            }
        }
        guard action == "execute" else { throw failure("UNKNOWN_ACTION", "未知文件操作") }
        let args = request["args"] as? [String:Any] ?? [:], agent = request["agent"] as? Bool ?? false
        let command = args["command"] as? String ?? ""
        if command == "ListAllowedDirectories" {
            return ["folders":registry.folders.filter {  $0.connected && (!agent || ["read","write"].contains($0.agentAccess)) }.map(folderInfo)]
        }
        let writes = ["WriteFile","AppendFile","EditFile","CopyFile","MoveFile","RenameFile","DeleteFile","CreateDirectory"]
        return try scoped(id, agent: agent, writing: writes.contains(command)) { root in
            let relative = args[command == "ListDirectory" || command == "CreateDirectory" ? "directoryPath" : command == "MoveFile" || command == "RenameFile" || command == "CopyFile" ? "sourcePath" : "filePath"] as? String ?? ""
            let target = try path(relative, root: root, allowRoot: ["ListDirectory","FileInfo"].contains(command))
            let dest = try (args["destinationPath"] as? String).map { try path($0, root: root) }
            if writes.contains(command) {
                guard let operationId = request["operationId"] as? String, !operationId.isEmpty, operationId.count <= 180 else { throw failure("INVALID_REQUEST", "修改操作缺少请求编号") }
                let signature = digest(try JSONSerialization.data(withJSONObject: ["folderId":id,"args":args], options: [.sortedKeys]))
                if let receipt = registry.receipts[operationId] {
                    guard receipt.signature == signature else { throw failure("REQUEST_CONFLICT", "请求编号已用于另一项操作") }
                    if let error = receipt.error { throw failure("PREVIOUS_FAILED", error) }; guard let result = receipt.result else { throw failure("CHECK_BACKUP", "此请求可能已执行，请检查当前文件与备份；不会重复执行") }
                    return try JSONSerialization.jsonObject(with: result)
                }
                registry.receipts[operationId] = Receipt(signature: signature, result: nil, at: now()); try save()
                let result: [String:Any]
                do { result = try coordinate(target, write: true, destination: dest, command: command) { current,destination in try mutate(command, args: args, root: root, target: current, destination: destination, folder: id, relative: relative) } }
                catch { registry.receipts[operationId]?.error = error.localizedDescription; try? save(); throw error }
                registry.receipts[operationId]?.result = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); try save(); return result
            }
            return try coordinate(target, write: false) { current,_ in
                _ = try path(relative, root: root, allowRoot: ["ListDirectory","FileInfo"].contains(command))
                switch command {
                case "ListDirectory":
                    let children = try fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey,.fileSizeKey,.isSymbolicLinkKey])
                    var entries: [[String:Any]] = []
                    for url in children.prefix(entryLimit) {
                        let rel = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { entries.append(["name":url.lastPathComponent,"path":rel,"type":"symlink","size":0,"modified":0,"version":"blocked"]); continue }
                        // Listing should not read every file's bytes. Versions are fetched on open/FileInfo.
                        let v = try url.resourceValues(forKeys: [.isDirectoryKey,.fileSizeKey,.contentModificationDateKey])
                        entries.append(["name":url.lastPathComponent,"path":rel,"type":v.isDirectory == true ? "directory":"file","size":v.fileSize ?? 0,"modified":Int64((v.contentModificationDate?.timeIntervalSince1970 ?? 0)*1000)])
                    }
                    return ["items":entries,"truncated":children.count > entryLimit]
                case "FileInfo": return fm.fileExists(atPath:current.path) ? try information(current, relative: relative) : ["path":relative,"type":"missing","version":"missing","exists":false]
                case "ReadFile":
                    let bytes = try data(current, limit: agent ? 200_000 : fileLimit); var result = try information(current, relative: relative)
                    result["base64"] = bytes.base64EncodedString(); if let text = String(data: bytes, encoding: .utf8) { result["text"] = text }; return result
                default: throw failure("UNSUPPORTED_COMMAND", "移动版暂不支持 \(command)")
                }
            }
        }
    }
    private func mutate(_ command: String, args: [String:Any], root: URL, target: URL, destination: URL?, folder: String, relative: String) throws -> [String:Any] {
        // Revalidate after coordination; a renamed ancestor or symlink must never expand the grant.
        _ = try path(relative, root: root)
        if let d = args["destinationPath"] as? String { _ = try path(d, root: root) }
        var backupId: String? = nil
        let exists = fm.fileExists(atPath: target.path)
        switch command {
        case "WriteFile","AppendFile","EditFile":
            var bytes: Data
            if args["encoding"] as? String == "base64" {
                guard let encoded = args["content"] as? String, let decoded = Data(base64Encoded: encoded) else { throw failure("INVALID_DATA", "Base64 内容无效") }; bytes = decoded
            } else {
                guard let text = args["content"] as? String else { throw failure("INVALID_DATA", "缺少文本内容") }; bytes = Data(text.utf8)
            }
            if exists {
                if command == "WriteFile" && args["overwrite"] as? Bool != true { throw failure("EXISTS", "同名文件已存在；明确覆盖并提供当前版本后才能修改") }
                try expected(args, target)
                let previous = try data(target)
                if command == "AppendFile" { bytes = previous + bytes }
                if command == "EditFile" {
                    guard let text = String(data: previous, encoding: .utf8), let old = args["oldText"] as? String, !old.isEmpty else { throw failure("INVALID_EDIT", "请提供非空的待替换文本") }
                    let occurrences = text.components(separatedBy: old).count - 1
                    guard occurrences == 1, let replacement = String(data: bytes, encoding: .utf8) else { throw failure("AMBIGUOUS_EDIT", "待替换文本必须恰好出现一次") }
                    bytes = Data(text.replacingOccurrences(of: old, with: replacement).utf8)
                }
                guard bytes.count <= fileLimit else { throw failure("FILE_LIMIT", "修改后的文件超过20MB") }
                backupId = try backup(target, folder: folder, relative: relative, command: command).id
            } else if command != "WriteFile" { throw failure("NOT_FOUND", "文件不存在") }
            guard bytes.count <= fileLimit else { throw failure("FILE_LIMIT", "文件超过20MB") }
            try bytes.write(to: target, options: exists ? .atomic : .withoutOverwriting)
        case "CreateDirectory":
            guard !exists else { throw failure("EXISTS", "同名项目已存在，未覆盖") }; try fm.createDirectory(at: target, withIntermediateDirectories: false)
        case "CopyFile","MoveFile","RenameFile":
            guard let destination = destination, let destRelative = args["destinationPath"] as? String, !fm.fileExists(atPath: destination.path), !inside(destination, target) else { throw failure("EXISTS", "目标已存在或是源目录的子目录，未覆盖") }
            try expected(args, target); try checkTree(target)
            if command == "CopyFile" { try fm.copyItem(at: target, to: destination) }
            else { backupId = try backup(target, folder: folder, relative: relative, command: command).id; try fm.moveItem(at: target, to: destination) }
            return ["path":destRelative,"version":try version(destination),"backupId":backupId ?? ""]
        case "DeleteFile":
            try expected(args, target); backupId = try backup(target, folder: folder, relative: relative, command: command).id; try fm.removeItem(at: target)
        default: throw failure("UNSUPPORTED_COMMAND", "未知修改操作")
        }
        return ["path":relative,"version":try version(target),"backupId":backupId ?? ""]
    }
}


public actor ConnectedFolders {
    private let storage: URL
    private var engine: ConnectedFolderEngine?
    public init(storage: URL) { self.storage = storage }
    private func owner() throws -> ConnectedFolderEngine {
        if let engine { return engine }
        let value = try ConnectedFolderEngine(storage: storage); engine = value; return value
    }
    public func connect(_ url: URL) throws -> JSONValue { try encode(owner().connect(url)) }
    public func request(_ request: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(request)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.server("文件请求无效") }
        return try encode(owner().handle(dictionary))
    }
    private func encode(_ value: Any) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self,from: JSONSerialization.data(withJSONObject: value,options: [.fragmentsAllowed])) }
}

public struct ConnectedDocument: Sendable {
    public var path: String; public var version: String; public var bytes: Data; public var text: String?
}
extension ConnectedFolders {
    public func execute(folderID: String,args: [String: JSONValue],operationID: String = UUID().uuidString,agent: Bool = false) throws -> JSONValue {
        try request(.object(["action": .string("execute"),"folderId": .string(folderID),"operationId": .string(operationID),"agent": .bool(agent),"args": .object(args)]))
    }
    public func read(folderID: String,path: String) throws -> ConnectedDocument {
        let value = try execute(folderID: folderID,args: ["command": .string("ReadFile"),"filePath": .string(path)])
        guard let data = Data(base64Encoded: value["base64"].text) else { throw ClientError.invalidResponse }
        return ConnectedDocument(path: path,version: value["version"].text,bytes: data,text: { if case .string(let s) = value["text"] { s } else { nil } }())
    }
}
