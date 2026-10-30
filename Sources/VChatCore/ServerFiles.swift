import Foundation
public struct ServerFileSettings: Codable, Sendable, Equatable {
    public var toolName = "ServerFileOperator"
    public var root = ""
    public var shareRoot = ""
    public init() {}
}
public enum ServerPath {
    public static func normalize(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\",with: "/").replacingOccurrences(of: "/+",with: "/",options: .regularExpression)
        guard !value.isEmpty,!value.unicodeScalars.contains(where: { $0.value < 32 }),!value.components(separatedBy: "/").contains(".."),value.hasPrefix("/") || value.range(of: "^[A-Za-z]:/",options: .regularExpression) != nil else { throw ClientError.server("请填写服务器上的绝对路径") }
        if value.range(of: "^[A-Za-z]:/$",options: .regularExpression) != nil { return value }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }; return value
    }
    public static func within(_ root: String,_ path: String) throws -> Bool {
        var r = try normalize(root), p = try normalize(path)
        if r.range(of: "^[A-Za-z]:",options: .regularExpression) != nil { r = r.lowercased(); p = p.lowercased() }
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
    public static func join(_ root: String,_ name: String) throws -> String { try normalize(normalize(root) + "/" + NotePath.segment(name)) }
    public static func block(tool: String,command: String,args: [String: JSONValue]) throws -> String {
        guard tool.range(of: "^[A-Za-z0-9_-]{1,80}$",options: .regularExpression) != nil else { throw ClientError.server("文件工具名称无效") }
        let fields = [("tool_name",tool),("command",command)] + args.keys.sorted().map { ($0,args[$0]!.bool.map { $0 ? "true" : "false" } ?? args[$0]!.text) }
        for (key,value) in fields { guard key.range(of: "^[A-Za-z0-9_]+$",options: .regularExpression) != nil,value.range(of: "「[始末]」|<<<|>>>",options: .regularExpression) == nil else { throw ClientError.server("参数含工具协议标记，无法通过此接口操作") } }
        return "<<<[TOOL_REQUEST]>>>\n" + fields.map { "\($0.0):「始」\($0.1)「末」" }.joined(separator: ",\n") + "\n<<<[END_TOOL_REQUEST]>>>"
    }
}
public struct RemoteFile: Sendable, Identifiable, Equatable {
    public var name: String; public var path: String; public var type: String; public var size: Double?; public var modified: String
    public var id: String { path }
}
public struct RemoteFileListing: Sendable { public var items: [RemoteFile]; public var truncated: Bool }
public struct RemoteFilePreview: Sendable { public var text: String; public var image: String }
public actor ServerFileClient {
    let config: ConnectionConfiguration; let settings: ServerFileSettings; let key: String; let fileKey: String
    let http = VCPHTTP(allowingRedirects: false)
    public init(configuration: ConnectionConfiguration,settings: ServerFileSettings,key: String,fileKey: String = "") { config = configuration; self.settings = settings; self.key = key; self.fileKey = fileKey }
    public func call(_ command: String,args: [String:JSONValue] = [:]) async throws -> (JSONValue,[JSONValue]) {
        guard !key.isEmpty else { throw ClientError.missingKey }
        let body = try ServerPath.block(tool: settings.toolName,command: command,args: args)
        let response = try await http.response(config.endpoint("v1/human/tool"),method: "POST",headers: ["Authorization": "Bearer " + key,"Content-Type": "text/plain"],body: Data(body.utf8))
        let data = (try? JSONDecoder().decode(JSONValue.self,from: response.data)) ?? .null
        guard (200..<300).contains(response.status), data["status"].text != "error", data["success"].bool != false else { let message = data["error"].text.isEmpty ? "文件操作 HTTP \(response.status)" : data["error"].text; throw ClientError.server(JSONValue.string(message).redacting([key,fileKey]).text) }
        guard data["status"].text == "success" || data["success"].bool == true || data["result"] != .null else { throw ClientError.server("文件操作未返回成功状态") }
        let result = data["result"] == .null ? data : data["result"]
        if result["success"].bool == false || result["status"].text == "error" { throw ClientError.server(result["error"].redacting([key,fileKey]).text.isEmpty ? "文件操作失败" : result["error"].redacting([key,fileKey]).text) }
        let details = result["details"] == .null ? (result["data"] == .null ? .object([:]) : result["data"]) : result["details"]
        return (details,result["content"].array)
    }
    private func check(_ path: String) throws { guard try ServerPath.within(settings.root,path) else { throw ClientError.server("目标路径不在当前浏览起点内") } }
    public func roots() async throws -> [String] { let (details,_) = try await call("ListAllowedDirectories"); return try details["allowedRoots"].object.keys.sorted().map(ServerPath.normalize) }
    public func list(_ path: String) async throws -> RemoteFileListing {
        try check(path); let (details,_) = try await call("ListDirectory",args: ["directoryPath": .string(try ServerPath.normalize(path)),"showHidden": .bool(false)])
        guard case .array(let rows) = details["items"] else { throw ClientError.server("服务器没有返回目录条目") }
        let items = try rows.map { value in let path = value["path"].text; guard try ServerPath.within(settings.root,path),["file","directory"].contains(value["type"].text) else { throw ClientError.server("服务器目录返回了范围外或无效条目") }; return RemoteFile(name: value["name"].text,path: path,type: value["type"].text,size: value["size"].number,modified: value["lastModified"].text) }
        return RemoteFileListing(items: items,truncated: details["truncated"].bool == true)
    }
    public func read(_ path: String) async throws -> RemoteFilePreview {
        try check(path); let (_,parts) = try await call("ReadFile",args: ["filePath": .string(path)])
        let image = parts.first { $0["type"].text == "image_url" }?["image_url"]["url"].text ?? ""
        return RemoteFilePreview(text: parts.filter { $0["type"].text == "text" }.map { $0["text"].text }.joined(separator: "\n\n"),image: image.range(of: "^data:image/(png|jpeg|gif|webp);base64,",options: [.regularExpression,.caseInsensitive]) == nil ? "" : image)
    }
    public func rename(_ source: String,destination: String,command: String) async throws {
        try check(source); try check(destination)
        guard ["RenameFile","CopyFile","MoveFile"].contains(command) else { throw ClientError.invalidConfiguration }
        if command == "MoveFile" {
            do { let (info,_) = try await call("FileInfo",args: ["filePath": .string(destination)]); if info["exists"].bool != false && info["type"].text != "missing" { throw ClientError.server("目标已存在，未移动或覆盖") } }
            catch let error as ClientError { if case .server(let text) = error, text.range(of: "ENOENT|not found|不存在",options: [.regularExpression,.caseInsensitive]) != nil {} else { throw error } }
        }
        _ = try await call(command,args: ["sourcePath": .string(source),"destinationPath": .string(destination)])
    }
    public func folder(_ path: String) async throws { try check(path); _ = try await call("CreateDirectory",args: ["directoryPath": .string(path)]) }
    public func remove(_ path: String) async throws { try check(path); _ = try await call("DeleteFile",args: ["filePath": .string(path)]) }
    public func upload(_ path: String,data: Data) async throws -> JSONValue { try check(path); guard data.count <= 10_000_000 else { throw ClientError.server("此工具单次上传上限为 10 MB") }; return try await call("WriteFile",args: ["filePath": .string(path),"content": .string(data.base64EncodedString()),"encoding": .string("base64")]).0 }
    public func download(_ path: String) async throws -> Data {
        try check(path); guard !fileKey.isEmpty,!settings.shareRoot.isEmpty else { throw ClientError.server("下载原文件需要 File Key 和服务端 file/ 目录映射") }
        let shared = try ServerPath.normalize(settings.shareRoot), path = try ServerPath.normalize(path)
        guard try ServerPath.within(shared,path) else { throw ClientError.server("此文件不在服务端 file/ 分发目录内，可读取提取内容或先复制到分发目录") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        let relative = path.dropFirst(shared.count).split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
        var parts = URLComponents(url: try config.endpoint(""),resolvingAgainstBaseURL: false)!; while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        parts.percentEncodedPath += "/pw=" + encoded(fileKey) + "/files/" + relative
        let response = try await http.response(parts.url!)
        guard (200..<300).contains(response.status) else { throw ClientError.http(response.status) }; return response.data
    }
}
