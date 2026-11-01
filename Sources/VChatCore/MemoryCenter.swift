import Foundation

public struct MemoryConnection: Sendable {
    public var configuration: ConnectionConfiguration
    public var username: String
    public var password: String
    public var chatKey: String
    public init(configuration: ConnectionConfiguration,username: String,password: String,chatKey: String) {
        self.configuration = configuration; self.username = username; self.password = password; self.chatKey = chatKey
    }
}
public struct MemoryDocument: Codable, Sendable, Identifiable {
    public var note: RemoteNote
    public var content: String
    public var id: String { note.id }
    public init(note: RemoteNote,content: String) { self.note = note; self.content = content }
}
public struct MemoryRecoveryPoint: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var createdAt = Date().timeIntervalSince1970
    public var operation: String
    public var documents: [MemoryDocument]
    public init(operation: String,documents: [MemoryDocument]) { self.operation = operation; self.documents = documents }
}
public struct MemorySearchResult: Sendable { public var notes: [RemoteNote]; public var output: String }
public struct MemoryAssociation: Sendable, Identifiable {
    public var note: RemoteNote
    public var score: Double
    public var tags: [String]
    public var id: String { note.id }
}
public actor MemoryHumanTools {
    let http = VCPHTTP(allowingRedirects: false)
    public init() {}
    public func call(_ connection: MemoryConnection,tool: String,args: [String:JSONValue]) async throws -> JSONValue {
        guard !connection.chatKey.isEmpty else { throw ClientError.missingKey }
        guard ["LightMemo","DailyNote"].contains(tool) else { throw ClientError.server("记忆工具无效") }
        var fields = [("tool_name",tool)]
        for (key,value) in args.sorted(by: { $0.key < $1.key }) {
            let text: String
            switch value { case .string(let s): text = s; case .number: text = value.text; case .bool(let b): text = b ? "true" : "false"; default: throw ClientError.server("工具参数类型无效") }
            guard key.range(of: "^[A-Za-z0-9_]+$",options: .regularExpression) != nil,text.range(of: "「[始末]」|<<<|>>>",options: .regularExpression) == nil else { throw ClientError.server("内容包含工具协议标记；请在已有文件的原文编辑器中保存这类示例") }
            fields.append((key,text))
        }
        let body = "<<<[TOOL_REQUEST]>>>\n" + fields.map { "\($0.0):「始」\($0.1)「末」" }.joined(separator: ",\n") + "\n<<<[END_TOOL_REQUEST]>>>"
        let reply = try await http.response(connection.configuration.endpoint("v1/human/tool"),method: "POST",headers: ["Authorization": "Bearer " + connection.chatKey,"Content-Type": "text/plain;charset=UTF-8"],body: Data(body.utf8),limit: 2_000_000)
        guard (200..<300).contains(reply.status) else { throw ClientError.http(reply.status) }
        let value = try JSONDecoder().decode(JSONValue.self,from: reply.data)
        try Self.validate(value,secrets: [connection.chatKey,connection.password])
        guard value["status"].text == "success" || value["success"].bool == true || value["result"] != .null else { throw ClientError.invalidResponse }
        return value
    }
    private static func validate(_ value: JSONValue,secrets: [String],depth: Int = 0) throws {
        guard depth < 12 else { throw ClientError.invalidResponse }
        guard value["status"].text != "error",value["success"].bool != false else {
            throw ClientError.server(value["error"].text.isEmpty ? "记忆工具执行失败" : value["error"].redacting(secrets).text)
        }
        if case .string(let text) = value,let parsed = try? JSONDecoder().decode(JSONValue.self,from: Data(text.utf8)),parsed != value {
            try validate(parsed,secrets: secrets,depth: depth + 1)
        }
        if case .array(let values) = value { for item in values { try validate(item,secrets: secrets,depth: depth + 1) } }
        for key in ["result","details","original_plugin_output"] where value[key] != .null {
            try validate(value[key],secrets: secrets,depth: depth + 1)
        }
    }
    public static func text(_ value: JSONValue,depth: Int = 0) -> String {
        guard depth < 12 else { return "" }
        if case .string(let s) = value {
            if let decoded = try? JSONDecoder().decode(JSONValue.self,from: Data(s.utf8)),decoded != value { let nested = text(decoded,depth: depth + 1); if !nested.isEmpty { return nested } }
            return s
        }
        if case .array(let rows) = value { return rows.map { text($0,depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        for key in ["original_plugin_output","result","content","text"] where value[key] != .null {
            let result = text(value[key],depth: depth + 1); if !result.isEmpty { return result }
        }
        return ""
    }
    public static func locator(_ raw: String,folder: String = "") throws -> RemoteNote {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\",with: "/")
        if path.hasPrefix("file:"),let url = URL(string: path) { path = url.path }
        path = path.removingPercentEncoding ?? path
        let pieces = path.split(separator: "/").map(String.init)
        guard let file = pieces.last,pieces.count >= 2 || !folder.isEmpty else { throw ClientError.invalidResponse }
        return RemoteNote(folder: try NotePath.segment(folder.isEmpty ? pieces[pieces.count - 2] : folder),file: try NotePath.segment(file))
    }
    public func semantic(_ c: MemoryConnection,query: String) async throws -> MemorySearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return MemorySearchResult(notes: [],output: "") }
        let value = try await call(c,tool: "LightMemo",args: ["maid": .string("Memo"),"query": .string(query),"k": .number(10),"tag_boost": .number(0.6),"search_all_knowledge_bases": .bool(true)])
        let output = Self.text(value)
        let split = try NSRegularExpression(pattern: #"(?m)(?=^---\s*\(来源\s*[:：])"#)
        let boundaries = split.matches(in: output,range: NSRange(output.startIndex...,in: output)).compactMap { Range($0.range,in: output)?.lowerBound }
        let starts = boundaries.isEmpty ? [output.startIndex] : boundaries
        let source = try NSRegularExpression(pattern: #"(?m)^---\s*\(来源\s*[:：]\s*(.+?)(?:[,，]\s*相关(?:性)?\s*[:：]|\)\s*$)"#)
        let path = try NSRegularExpression(pattern: #"(?m)^\s*\[路径\s*[:：]\s*(.+?)\]\s*$"#)
        func capture(_ regex: NSRegularExpression,_ s: String) -> String? {
            guard let match = regex.firstMatch(in: s,range: NSRange(s.startIndex...,in: s)),let range = Range(match.range(at: 1),in: s) else { return nil }; return String(s[range])
        }
        var notes: [String:RemoteNote] = [:]
        for (i,start) in starts.enumerated() {
            let section = String(output[start..<(i + 1 < starts.count ? starts[i + 1] : output.endIndex)])
            guard let file = capture(path,section),var note = try? Self.locator(file,folder: capture(source,section) ?? "") else { continue }
            note.preview = String(section.split(separator: "\n").filter { !$0.hasPrefix("---") && !$0.hasPrefix("[路径") }.joined(separator: " ").prefix(180))
            if (notes[note.id]?.preview.count ?? 0) < note.preview.count { notes[note.id] = note }
        }
        return MemorySearchResult(notes: notes.values.sorted { $0.id < $1.id },output: output)
    }
}
extension DailyNotesClient {
    private func memoryCall(_ c: MemoryConnection,path: [String],query: [URLQueryItem] = [],body: JSONValue? = nil) async throws -> JSONValue {
        let value = try await call(c.configuration,username: c.username,password: c.password,path: path,query: query,body: body)
        guard value["success"].bool != false,value["status"].text != "error",value["errors"].array.isEmpty else { throw ClientError.server("服务器报告操作失败或部分失败；修改前备份仍保留，请刷新列表核对") }
        return value
    }
    public func searchMemory(_ c: MemoryConnection,query: String,folder: String? = nil) async throws -> [RemoteNote] {
        var items = [URLQueryItem(name: "term",value: query)]
        if let folder { items.append(URLQueryItem(name: "folder",value: try NotePath.segment(folder))) }
        let result = try await memoryCall(c,path: ["search"],query: items)
        let rows = result["notes"] == .null ? result["memos"] : result["notes"]
        guard case .array = rows else { throw ClientError.invalidResponse }
        return summaries(rows,fallback: folder ?? "")
    }
    public func memoryDocument(_ c: MemoryConnection,note: RemoteNote) async throws -> MemoryDocument {
        MemoryDocument(note: note,content: try await read(c.configuration,username: c.username,password: c.password,folder: note.folder,file: note.file))
    }
    public func backupMemories(_ c: MemoryConnection,notes: [RemoteNote],operation: String,store: ChatStore) async throws -> MemoryRecoveryPoint {
        guard !notes.isEmpty,notes.count <= 100 else { throw ClientError.server("一次请选择1–100篇记忆") }
        var documents: [MemoryDocument] = [], bytes = 0
        for note in notes {
            try Task.checkCancellation(); let document = try await memoryDocument(c,note: note); bytes += document.content.utf8.count
            guard bytes <= 20_000_000 else { throw ClientError.server("本批备份超过20MB，请拆小批次") }; documents.append(document)
        }
        let point = MemoryRecoveryPoint(operation: operation,documents: documents)
        try await store.put(point,kind: "memory-recovery",id: point.id)
        return point
    }
    public func updateMemory(_ c: MemoryConnection,original: MemoryDocument,file: String,content: String,store: ChatStore) async throws {
        let current = try await memoryDocument(c,note: original.note)
        guard current.content == original.content else { throw ClientError.server("记忆已被外部修改，请重新打开后编辑；当前草稿仍保留") }
        let filename = try NotePath.filename(file)
        if filename != original.note.file {
            let list = try await notes(c.configuration,username: c.username,password: c.password,folder: original.note.folder)
            guard !list.contains(where: { $0.file == filename }) else { throw ClientError.server("目标文件名已存在，不会覆盖") }
        }
        let point = MemoryRecoveryPoint(operation: "编辑 \(original.note.id)",documents: [current]); try await store.put(point,kind: "memory-recovery",id: point.id)
        _ = try await memoryCall(c,path: ["note",original.note.folder,original.note.file],body: .object(["content": .string(content),"newFileName": .string(filename)]))
    }
    public func createMemory(_ c: MemoryConnection,folder: String,file: String,content: String) async throws {
        let folder = try NotePath.segment(folder),file = try NotePath.filename(file)
        let folders = try await folders(c.configuration,username: c.username,password: c.password)
        if folders.contains(folder) {
            let existing = try await notes(c.configuration,username: c.username,password: c.password,folder: folder)
            guard !existing.contains(where: { $0.file == file }) else { throw ClientError.server("同名记忆已存在，不会覆盖") }
            _ = try await memoryCall(c,path: ["note",folder,file],body: .object(["content": .string(content)]))
        } else {
            let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.locale = Locale(identifier: "en_US_POSIX")
            _ = try await MemoryHumanTools().call(c,tool: "DailyNote",args: ["maid": .string(folder),"command": .string("create"),"Date": .string(format.string(from: Date())),"fileName": .string(file),"Content": .string(content)])
        }
    }
    public func publishMemory(_ c: MemoryConnection,folder: String,file: String,date: Date,author: String,tags: String,content: String) async throws {
        let folder = try NotePath.segment(folder),file = try NotePath.filename(file)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.server("请先填写记忆正文") }
        let available = try await folders(c.configuration,username: c.username,password: c.password)
        if available.contains(folder) {
            let list = try await notes(c.configuration,username: c.username,password: c.password,folder: folder)
            guard !list.contains(where: { $0.file == file }) else { throw ClientError.server("同名记忆已存在，请换一个文件名") }
        }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        let maid = author.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String:JSONValue] = ["maid": .string(maid.isEmpty ? folder : maid),"folder": .string(folder),"command": .string("create"),"Date": .string(format.string(from: date)),"fileName": .string(file),"Content": .string(content)]
        if !tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["Tag"] = .string(tags) }
        _ = try await MemoryHumanTools().call(c,tool: "DailyNote",args: args)
    }
    public func moveMemories(_ c: MemoryConnection,notes selected: [RemoteNote],target: String,store: ChatStore) async throws {
        let target = try NotePath.segment(target)
        guard selected.allSatisfy({ $0.folder != target }),Set(selected.map(\.file)).count == selected.count else { throw ClientError.server("目标目录与来源相同，或选中文件有重名，请分批移动") }
        let folders = try await folders(c.configuration,username: c.username,password: c.password)
        if folders.contains(target) {
            let destinations = try await notes(c.configuration,username: c.username,password: c.password,folder: target)
            guard Set(destinations.map(\.file)).isDisjoint(with: Set(selected.map(\.file))) else { throw ClientError.server("目标目录有同名文件，不会覆盖") }
        }
        _ = try await backupMemories(c,notes: selected,operation: "移动到 \(target)",store: store)
        _ = try await memoryCall(c,path: ["move"],body: .object(["sourceNotes": .array(selected.map { .object(["folder": .string($0.folder),"file": .string($0.file)]) }),"targetFolder": .string(target)]))
    }
    public func deleteMemories(_ c: MemoryConnection,notes: [RemoteNote],store: ChatStore) async throws {
        _ = try await backupMemories(c,notes: notes,operation: "删除记忆",store: store)
        _ = try await memoryCall(c,path: ["delete-batch"],body: .object(["notesToDelete": .array(notes.map { .object(["folder": .string($0.folder),"file": .string($0.file)]) })]))
    }
    public func deleteMemoryFolder(_ c: MemoryConnection,folder: String) async throws {
        guard try await notes(c.configuration,username: c.username,password: c.password,folder: folder).isEmpty else { throw ClientError.server("只允许删除空文件夹，请先整理其中的记忆") }
        _ = try await memoryCall(c,path: ["folder","delete"],body: .object(["folderName": .string(try NotePath.segment(folder))]))
    }
    public func restoreMemories(_ c: MemoryConnection,point: MemoryRecoveryPoint) async throws {
        for document in point.documents {
            try Task.checkCancellation()
            do {
                let current = try await memoryDocument(c,note: document.note)
                guard current.content == document.content else { throw ClientError.server("\(document.note.id)已存在不同内容，不会覆盖；可从备份复制原文") }
            } catch ClientError.http(404) {
                try await createMemory(c,folder: document.note.folder,file: document.note.file,content: document.content)
            }
        }
    }
    public func associations(_ c: MemoryConnection,note: RemoteNote,k: Int,folders: [String],tagBoost: String) async throws -> [MemoryAssociation] {
        let boost = tagBoost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...30).contains(k),boost.range(of: "^[0-9]+(?:\\.[0-9]+)?\\+?$",options: .regularExpression) != nil,let number = Double(boost.hasSuffix("+") ? String(boost.dropLast()) : boost),(0...2).contains(number) else { throw ClientError.server("联想参数无效；标签增强可填0.6或0.6+") }
        let path = try NotePath.segment(note.folder) + "/" + NotePath.segment(note.file)
        let value = try await memoryCall(c,path: ["associative-discovery"],body: .object(["sourceFilePath": .string(path),"k": .number(Double(k)),"range": .array(try (folders.isEmpty ? [note.folder] : folders).map { .string(try NotePath.segment($0)) }),"tagBoost": .string(boost)]))
        guard case .array(let rows) = value["results"] else { throw ClientError.invalidResponse }
        return try rows.prefix(100).map { row in
            var linked = try MemoryHumanTools.locator(row["path"].text); linked.preview = String(row["chunks"].array.map { $0.text.isEmpty ? $0["text"].text : $0.text }.joined(separator: "\n").prefix(500))
            return MemoryAssociation(note: linked,score: row["score"].number ?? 0,tags: row["matchedTags"].array.map { $0.text.isEmpty ? $0["tag"].text : $0.text })
        }
    }
}
