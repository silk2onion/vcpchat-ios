import Foundation
public struct FileNodeSettings: Codable, Sendable, Equatable {
    public var server = ""
    public var name = "VCPChat Mobile"
    public var deviceID = UUID().uuidString
    public var enabled = false
    public init() {}
}
public enum MobileFileTool {
    public static let commands = ["ListAllowedDirectories","ListDirectory","FileInfo","ReadFile","WriteFile","AppendFile","EditFile","CopyFile","MoveFile","RenameFile","DeleteFile","CreateDirectory"]
    public static func manifest(deviceID: String) throws -> JSONValue {
        let suffix = deviceID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !suffix.isEmpty, suffix.count <= 80 else { throw ClientError.server("设备标识无效") }
        return .object(["name": .string("MobileFileOperator_" + suffix),"displayName": .string("移动文件操作器"),"pluginType": .string("synchronous"),"entryPoint": .object(["command": .string("native:connected-folders")]),"communication": .object(["protocol": .string("direct"),"timeout": .number(120000)]),"version": .string("1.0.0"),"description": .string("直接操作本设备经用户连接并授权的文件夹，修改前保存备份。路径必须相对于folderId；不访问未授权目录。"),"capabilities": .object(["invocationCommands": .array(commands.map { .object(["command": .string($0),"description": .string($0 == "ListAllowedDirectories" ? "列出已授权Agent的文件夹id、名称和权限，不返回系统绝对路径。" : "必需folderId。路径相对于该目录；ListDirectory用directoryPath（根目录空字符串），文件用filePath，复制/移动/改名用sourcePath与destinationPath。ReadFile上限200KB；修改前ReadFile或FileInfo取得expectedVersion。WriteFile用content及encoding(utf8/base64)，覆盖须overwrite:true。EditFile用oldText和content作单次唯一替换。文件上限20MB，目录备份上限100MB/2000项，同名目标不覆盖。")]) })])])
    }
    public static func endpoint(server: String,key: String) throws -> URL {
        guard !key.isEmpty, var c = URLComponents(string: server),["http","https","ws","wss"].contains(c.scheme),c.host != nil,c.user == nil,c.password == nil,c.query == nil,c.fragment == nil else { throw ClientError.server("请填写不带密钥或查询参数的 VCP 分布式地址") }
        // The backend compares raw paths; reuse the raw-safe key validation.
        _ = try SocketEndpoint.url(server: server,key: key,channel: .info)
        c.scheme = ["https","wss"].contains(c.scheme) ? "wss" : "ws"
        var path = c.percentEncodedPath; while path.hasSuffix("/") { path.removeLast() }; if path.hasSuffix("/vcp-distributed-server") { path.removeLast("/vcp-distributed-server".count) }
        c.percentEncodedPath = path + "/vcp-distributed-server/VCP_Key=" + key
        guard let url = c.url else { throw ClientError.invalidConfiguration }; return url
    }
    public static func execute(_ input: JSONValue,requestID: String,folders: ConnectedFolders) async throws -> JSONValue {
        guard case .object(var args) = input, commands.contains(input["command"].text), !requestID.isEmpty,requestID.count <= 160 else { throw ClientError.server("移动文件操作器参数或指令无效") }
        if args["overwrite"] != nil { args["overwrite"] = .bool(input["overwrite"].bool == true || input["overwrite"].text == "true") }
        let value = try await folders.execute(folderID: input["folderId"].text,args: args,operationID: requestID,agent: true)
        return .object(["status": .string("success"),"result": .object(["details": value,"content": .array([.object(["type": .string("text"),"text": .string(value["text"].text.isEmpty ? value.pretty : value["text"].text)])])])])
    }
}
public actor MobileFileNode {
    private let folders: ConnectedFolders
    private let socket = JSONSocket()
    private var task: Task<Void,Never>?
    private var timeout: Task<Void,Never>?
    private var generation: UUID?
    private var continuation: AsyncStream<String>.Continuation?
    private var acknowledged = false
    public init(folders: ConnectedFolders) { self.folders = folders }
    public func start(_ settings: FileNodeSettings,key: String) async throws -> AsyncStream<String> {
        await stop(); let url = try MobileFileTool.endpoint(server: settings.server,key: key), manifest = try MobileFileTool.manifest(deviceID: settings.deviceID), id = UUID(); generation = id
        let (updates,c) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8)); continuation = c
        task = Task {
            while !Task.isCancelled && generation == id {
                c.yield("正在鉴权"); acknowledged = false
                let stream = await socket.connect(url)
                timeout = Task { do { try await Task.sleep(for: .seconds(10)) } catch { return }; if generation == id && !acknowledged { await socket.close() } }
                do { for try await message in stream {
                    guard generation == id, !Task.isCancelled else { return }
                    if message["type"].text == "connection_ack" {
                        timeout?.cancel(); acknowledged = true
                        try await socket.send(.object(["type": .string("register_tools"),"data": .object(["serverName": .string(settings.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "VCPChat Mobile" : settings.name),"tools": .array([manifest])])]))
                        c.yield("已连接"); continue
                    }
                    guard acknowledged,message["type"].text == "execute_tool" else { continue }
                    let data = message["data"], requestID = data["requestId"].text
                    guard !requestID.isEmpty,requestID.count <= 160,data["toolName"].text == manifest["name"].text else { continue }
                    var answer: [String: JSONValue] = ["requestId": .string(requestID)]
                    do { answer["result"] = try await MobileFileTool.execute(data["toolArgs"],requestID: requestID,folders: folders); answer["status"] = .string("success") }
                    catch { answer["status"] = .string("error"); answer["error"] = .string(error.localizedDescription) }
                    guard generation == id,!Task.isCancelled else { return }
                    try await socket.send(.object(["type": .string("tool_result"),"data": .object(answer)]))
                } } catch { if Task.isCancelled || generation != id { return } }
                timeout?.cancel(); await socket.close(); guard generation == id,!Task.isCancelled else { return }
                c.yield("已断开，3 秒后重连"); do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        return updates
    }
    public func stop() async { generation = nil; task?.cancel(); task = nil; timeout?.cancel(); timeout = nil; await socket.close(); continuation?.yield("未连接"); continuation?.finish(); continuation = nil }
}
